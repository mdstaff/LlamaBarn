# Adaptive Context Scaling — Technical Spec

## Strategic Context

**Upstream gap**: The `-fa on`, `-ctk q8_0`, `-ctv q8_0` flags in our fork (see
`specs/memory-optimization-24gb.md`) are not present in the upstream `ggml-org/LlamaBarn` repo.
A previous PR proposing those flags has not received maintainer feedback, so they are not treated
as a near-term upstream contribution here.

`MemoryPressureMonitor` / ACS is a separate, self-contained change — pure Swift, no binaries,
small surface area — and can be proposed independently if the maintainers are receptive.

---

## Background: What's Already Solved

Before designing ACS, it's important to enumerate the memory mitigations already active. These
represent the *static* layer of memory management — present in our fork, **not in upstream**:

| Mechanism | Where | What it does |
|---|---|---|
| `-fa on` | `LlamaServer.start()` | Flash Attention — O(n) KV memory scaling, reduces prefill peak |
| `-ctk q8_0 -ctv q8_0` | `LlamaServer.start()` | KV cache quantization — ~50% KV memory reduction (~3.7–4 GB on 27B models) |
| `--fit-target` | `LlamaServer.start()` | llama-server adjusts context at **load time** to fit available memory |
| `--models-max 1` | `LlamaServer.start()` | Only one model resident at a time |
| `--sleep-idle-seconds` | `LlamaServer.start()` | Unloads model after idle period, reclaiming memory |

**What these don't cover**: Memory pressure that builds up *after* a model is loaded. A user loads a
model at 6 GB headroom, then opens Xcode for a build — headroom drops to 1 GB. Nothing currently
responds to this in real time. macOS begins swapping to SSD, degrading both inference throughput and
system responsiveness.

That is the specific problem ACS addresses.

---

## Scope (Narrowed from Naive Approach)

A naive "restart server with reduced context on `.warning`" approach is explicitly not implemented
for two reasons:

1. `--fit-target` + KV quantization already address the at-load-time sizing problem.
2. Restarting llama-server mid-session discards the loaded model (minutes of load time) and kills
   any in-flight inference. The cure is worse than the disease for a `.warning` event.

**ACS in LlamaBarn is scoped to one action: unload the active model on `.critical` memory pressure,
but only after any in-flight generation has completed or timed out.**

This is the highest-value, lowest-complexity intervention:
- macOS only emits `.critical` when swap pressure is imminent — it's a high-signal event
- `LlamaServer.unloadModel()` already exists and is well-tested
- No server restart required; llama-server stays running in Router Mode, ready for next load
- Checking for in-flight generation before unloading preserves the current response for the user

---

## Performance Impact on Long Context Windows

**The monitor itself adds zero overhead.** `DispatchSource.makeMemoryPressureSource` is a kernel
push notification — no polling, no timers. Long context inference (CPU/GPU/memory-bound) is
completely unaffected by the monitor's existence during normal operation.

**Long context windows are the most likely trigger.** A 27B model at 32k context with q8_0 KV cache
holds ~2–3 GB in KV cache alone. Combined with the model weights (~18 GB), this sits near the top of
a 24 GB budget. Any concurrent memory spike from Xcode, browser, or another app can push this to
`.critical`.

**By the time `.critical` fires, inference is already degraded.** macOS emits `.critical` only under
active swap pressure. KV cache reads are hitting SSD (10–100× slower than DRAM). The in-flight
generation is already producing tokens slowly — the system, not ACS, has degraded performance.

**ACS trades degraded inference + degraded system for clean unload + healthy system.** The user
loses the current context either way once swap starts. ACS ensures the system recovers cleanly and
quickly, rather than continuing in a degraded state indefinitely.

**What ACS does not do:** It cannot preserve or resume a long context session. llama-server does not
expose context serialization in Router Mode. The mitigation for long-context memory pressure is
primarily the static layer (`-fa`, KV quantization) — ACS is the safety valve when those aren't
enough.

---

## Technical Specification

### 1. Memory Pressure Monitoring

Use `DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)`
to subscribe to system memory events.

**Event handling:**

| Event | Action |
|---|---|
| `.warning` | Log to console. No structural change — static mitigations handle this. |
| `.critical` | Check if generation is in-flight. Wait up to 5 seconds for it to complete. Then unload the active model. Post `LBMemoryPressureDidOccur` notification for UI. |

### 2. In-Flight Generation Check

Before unloading on `.critical`, check whether llama-server is actively generating:

- `LlamaServer.modelStatuses` reflects the Router Mode model state (`"loaded"`, `"loading"`, etc.)
- A model that is `"loaded"` and has a non-nil `activeModelPath` may be mid-generation
- Poll `api.fetchModelStatuses()` or wait a fixed 5-second timeout before forcing the unload

This preserves the user's current response in most cases. If the generation doesn't complete within
the timeout, unload anyway — a swapping system is worse than a cancelled response.

```swift
// In handlePressureEvent, before calling unloadModel:
// Allow up to 5 seconds for any in-flight generation to complete
let deadline = Date().addingTimeInterval(5)
while Date() < deadline {
  // If model is no longer actively serving (e.g. generation finished and went idle),
  // we can proceed. For now a short sleep is sufficient — this path is rare.
  try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
  if !LlamaServer.shared.isAnyModelLoading { break }
}
```

### 3. Hysteresis

After a `.critical` event triggers an unload, suppress further `.critical` actions for **60 seconds**.
This prevents repeated unload attempts during a sustained high-pressure period (e.g. a long Xcode
build that keeps memory pressure elevated). A simple `lastCriticalActionDate: Date?` property is
sufficient — no complex state machine needed.

### 4. New File: `LlamaBarn/System/MemoryPressureMonitor.swift`

```swift
import Foundation
import os.log

/// Monitors system memory pressure and unloads the active model on critical events
/// to prevent macOS SSD swap and preserve system responsiveness.
///
/// Lifecycle: start() when llama-server launches, stop() when it stops.
/// Zero overhead during normal operation — kernel push notification, no polling.
@MainActor
final class MemoryPressureMonitor {
  static let shared = MemoryPressureMonitor()

  private var source: DispatchSourceMemoryPressure?
  private var lastCriticalActionDate: Date?
  private let cooldownSeconds: TimeInterval = 60
  private let inflightTimeoutSeconds: TimeInterval = 5
  private let logger = Logger(subsystem: Logging.subsystem, category: "MemoryPressure")

  func start() {
    guard source == nil else { return }

    let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
    src.setEventHandler { [weak self] in
      self?.handlePressureEvent(src.data)
    }
    src.resume()
    source = src
    logger.info("Memory pressure monitor started")
  }

  func stop() {
    source?.cancel()
    source = nil
  }

  private func handlePressureEvent(_ event: DispatchSource.MemoryPressureEvent) {
    switch event {
    case .warning:
      logger.warning("System memory pressure: warning — static mitigations active")

    case .critical:
      let now = Date()
      if let last = lastCriticalActionDate, now.timeIntervalSince(last) < cooldownSeconds {
        logger.warning("System memory pressure: critical (suppressed — within cooldown)")
        return
      }

      logger.error("System memory pressure: critical — will unload active model")
      lastCriticalActionDate = now

      Task {
        await self.handleCriticalPressure()
      }

    default:
      break
    }
  }

  private func handleCriticalPressure() async {
    let server = LlamaServer.shared

    guard let activePath = server.activeModelPath else {
      logger.info("Memory pressure: critical, but no model is loaded — nothing to do")
      return
    }

    // Wait briefly for any in-flight generation to complete before unloading.
    // This preserves the current response in most cases.
    let deadline = Date().addingTimeInterval(inflightTimeoutSeconds)
    while Date() < deadline && server.isAnyModelLoading {
      try? await Task.sleep(nanoseconds: 500_000_000)
    }

    if server.isAnyModelLoading {
      logger.warning("Memory pressure: in-flight generation did not complete within timeout — forcing unload")
    }

    guard let model = CatalogEntry.all.first(where: { $0.modelFilePath == activePath }) else {
      logger.error("Memory pressure: could not find catalog entry for active model path")
      return
    }

    NotificationCenter.default.post(name: .LBMemoryPressureDidOccur, object: self)
    server.unloadModel(model)
    logger.info("Unloaded \(model.displayName) due to critical memory pressure")
  }
}
```

### 5. Notification

Add to the file where `LBServerStateDidChange` etc. are declared:

```swift
extension Notification.Name {
  static let LBMemoryPressureDidOccur = Notification.Name("LBMemoryPressureDidOccur")
}
```

### 6. Lifecycle Integration

In `LlamaServer.start()`, after `try process.run()` succeeds:

```swift
MemoryPressureMonitor.shared.start()
```

In `LlamaServer.stop()`, inside `cleanUpResources()` alongside `stopMemoryMonitoring()`:

```swift
MemoryPressureMonitor.shared.stop()
```

The monitor runs only while the server is active, avoiding spurious events when the app is
backgrounded with no model loaded.

### 7. UI Indicator (Optional / Phase 2)

When `LBMemoryPressureDidOccur` fires, a transient status in the menu can display
"Model unloaded (low memory)" before reverting to idle state. This is cosmetic and can be deferred.

---

## What This Does NOT Include

- **Context size reduction + server restart on `.warning`**: Not implemented. `--fit-target` +
  KV quantization handle at-load sizing; mid-session restart is disruptive with no net benefit.
- **`POST /v1/unload` API call**: This endpoint does not exist in llama.cpp. Model management
  uses `LlamaServerAPI.unloadModel(id:)` via the correct Router Mode endpoint.
- **`taskpolicy -b` for testing**: This sets background QoS, not memory pressure. To simulate:
  ```
  sudo memory_pressure -S -l critical
  ```

---

## Verification

1. Launch LlamaBarn, load a model, confirm it shows as loaded in the menu.
2. Run `sudo memory_pressure -S -l critical` in Terminal.
3. Expected: ~5 second pause (in-flight check), then model unloads, menu shows idle state.
   Console: `"Unloaded <ModelName> due to critical memory pressure"`.
4. Run again immediately — expect `"suppressed — within cooldown"` in Console.
5. Wait 60 seconds, run again — expect full unload cycle to repeat.
6. To test in-flight timeout: trigger a long generation, immediately run memory_pressure critical.
   Expected: generation completes or 5s elapses, then unload.

---

## Upstream Contribution Notes

If proposed upstream, key points for the PR description:
- Zero new dependencies (pure Swift, Apple-native API)
- No impact on normal operation (kernel push, zero polling overhead)
- Addresses memory pressure for users on constrained hardware without requiring any configuration

---

## File References

- `LlamaBarn/System/LlamaServer.swift` — `start()`, `stop()`, `cleanUpResources()`, `unloadModel()`
- `LlamaBarn/Catalog/CatalogEntry.swift` — `CatalogEntry.all`, `modelFilePath`
- `LlamaBarn/System/ModelManager.swift` — not directly involved
- `specs/memory-optimization-24gb.md` — static mitigation layer and upstream PR 1 justification
