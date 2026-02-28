# activeModelPath Refactor — Technical Spec

> **Status: Implemented** — merged into `dev` as `feat/active-model-path-refactor`.

## Problem

`LlamaServer.activeModelPath` is manually managed state that can drift from reality.
It is written from **7 locations across 2 files**, none of which are guaranteed to fire
when a model is loaded or unloaded externally (e.g. via the Web UI or llama-server's
own sleep/idle logic).

This causes `MemoryPressureMonitor` — and any future consumer — to see a stale or nil
`activeModelPath` even when a model is fully loaded and serving requests.

### Current write sites

| Location | Action |
|---|---|
| `LlamaServer.start()` — launch failure path | Set to `nil` |
| `LlamaServer.stop()` | Set to `nil` |
| `LlamaServer.loadModel()` | Set to `model.modelFilePath` |
| `LlamaServer.unloadModel()` | Set to `nil` if matches |
| `LlamaServer.checkStatus()` — sleep/idle path | Set to `nil` |
| `LlamaServer.checkStatus()` — polling sync patch | Set from polling (band-aid) |
| `ModelManager.deleteDownloadedModel()` | Set to `nil` if matches |

### Symptom observed

Loading a model via the Web UI bypasses `loadModel()`. `modelStatuses` is updated
by polling to `"loaded"` within 1 second, but `activeModelPath` stays `nil`.
`MemoryPressureMonitor.handleCriticalPressure()` bails out with
`"no model is loaded — nothing to do"` even though the model is fully loaded.

---

## Goal

Make `activeModelPath` a **computed property** derived from `modelStatuses` and the
catalog. This eliminates the possibility of drift — the value is always consistent
with what the 1-second poll reports from llama-server.

---

## Proposed Solution

### 1. Replace the stored property with a computed property

In `LlamaServer.swift`, replace:

```swift
var activeModelPath: String?
```

With:

```swift
var activeModelPath: String? {
  guard let loadedId = modelStatuses.first(where: { $0.value == "loaded" })?.key else {
    return nil
  }
  return Catalog.allModels().first(where: { $0.id == loadedId })?.modelFilePath
}
```

`modelStatuses` already has a `didSet` that posts `LBModelStatusDidChange` — all
existing observers continue to work without changes.

### 2. Remove all manual write sites

Remove every assignment to `activeModelPath` across both files:

- `LlamaServer.start()` — remove `self.activeModelPath = nil`
- `LlamaServer.stop()` — remove `activeModelPath = nil`
- `LlamaServer.loadModel()` — remove `self.activeModelPath = model.modelFilePath`
- `LlamaServer.unloadModel()` — remove the `if activeModelPath == ... { activeModelPath = nil }` block
- `LlamaServer.checkStatus()` — remove both the sleep/idle nil-set and the polling sync patch added in this session
- `ModelManager.deleteDownloadedModel()` — remove the `llamaServer.activeModelPath = nil` block (deletion triggers an unload which updates `modelStatuses` via polling)

### 3. Update the load log

`loadModel()` currently logs when `activeModelPath` is set. Move this log to fire
when `modelStatuses` transitions to `"loaded"` in `checkStatus()`, since that is
now the source of truth:

```swift
// In checkStatus(), inside the MainActor.run block:
let previouslyLoaded = self.modelStatuses.first(where: { $0.value == "loaded" })?.key
if let newLoadedId = newStatuses.first(where: { $0.value == "loaded" })?.key,
   newLoadedId != previouslyLoaded,
   let model = Catalog.allModels().first(where: { $0.id == newLoadedId }) {
  let effectiveCtx = model.effectiveCtxTier?.label ?? "\(model.ctxWindow / 1024)k"
  self.logger.info("Model loaded: \(model.displayName, privacy: .public) | ctx: \(effectiveCtx, privacy: .public) | quant: \(model.quantization, privacy: .public) | size: \(model.fileSize / 1_000_000, privacy: .public) MB")
}
```

---

## What Does NOT Change

- `modelStatuses` — unchanged, remains the polling-driven source of truth
- `LBModelStatusDidChange` notification — unchanged, still fires on every poll diff
- `isActive(model:)` — unchanged, already reads from `modelStatuses`
- `isLoading(model:)` — unchanged
- `MemoryPressureMonitor` — unchanged, `activeModelPath` access just becomes correct
- All UI consumers of `activeModelPath` — unchanged

---

## Risks and Mitigations

| Risk | Mitigation |
|---|---|
| Up to 1s lag before `activeModelPath` reflects a load | Acceptable — polling is already the source of truth for all UI state. `MemoryPressureMonitor` doesn't need sub-second accuracy. |
| `ModelManager.deleteDownloadedModel()` relied on writing `activeModelPath = nil` directly | Deletion calls `unloadModel()` via the API which updates `modelStatuses` within the next poll. No behavioural change. |
| `loadModel()` set `activeModelPath` optimistically before the server confirmed load | The optimistic UI state is already handled by `modelStatuses[model.id] = "loading"` in `loadModel()`. The path was redundant. |

---

## File References

- `LlamaBarn/System/LlamaServer.swift` — primary change site
- `LlamaBarn/Models/ModelManager.swift` — remove write site
- `LlamaBarn/System/MemoryPressureMonitor.swift` — remove debug log line (no longer needed once fixed)
- `specs/adaptive-context-scaling.md` — consumer of `activeModelPath`
