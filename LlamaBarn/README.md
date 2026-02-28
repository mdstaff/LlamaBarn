# LlamaBarn — Project Walkthrough

## What It Is

LlamaBarn is a **macOS menu bar app** (Swift/AppKit) from **ggml-org** — the organization behind llama.cpp, maintained by ggerganov and 3 contributors. It lets users download, manage, and run local LLM models entirely on-device. The app sits in the system tray (no Dock icon) and serves models via a local HTTP API on port 2276.

**Contributors:** erusev (Emanuil Rusev), astoilkov (Antonio Stoilkov), julien-c (Julien Chaumond)

---

## Top-Level Structure

```
LlamaBarn/
├── LlamaBarn/           # Swift app source
├── llama-cpp/           # Bundled llama-server binary + dylibs
├── LlamaBarn.xcodeproj/
├── scripts/             # Build scripts (build-archive.sh, export-options.plist)
├── specs/               # Technical specs for fork-specific changes
└── contributing.md
```

---

## LlamaBarn Source — Folder by Folder

### `LlamaBarnApp.swift` — Entry Point
- `@main` SwiftUI `App` struct, but the real work is in `AppDelegate`
- On launch: initializes Sentry (error reporting, release builds only), Sparkle (auto-updates), `ModelManager`, `MenuController`, `SettingsWindowController`, and starts `LlamaServer`
- Sets activation policy to `.accessory` (menu bar only, no Dock icon)
- Sparkle uses "gentle reminders" mode — update dialogs temporarily switch the app to `.regular` policy so the dialog appears properly, then revert

### `Catalog/` — Model Registry
- `Catalog.swift` / `Catalog+Data.swift`: static list of all available models with their Hugging Face download URLs, file sizes, context windows, quantization info
- `CatalogEntry.swift`: the core model descriptor struct — holds metadata, file paths, memory estimates, and server args per model. Key fields:
  - `downloadUrl` / `additionalParts` / `mmprojUrl` — file locations (supports sharded and vision models)
  - `ctxBytesPer1kTokens` — used to estimate KV-cache memory before launching
  - `overheadMultiplier` — accounts for loading overhead in memory calculations
  - `serverArgs` — model-specific llama-server flags (e.g. `--temp 0.7`)
- `CatalogEntry+Compatibility.swift`: checks whether a model fits in available unified memory
- `ContextTier.swift`, `ModelSize.swift`, `ModelFamily.swift`: supporting enums for categorization and display ordering

### `Models/` — Download & State Management
- `ModelManager.swift`: the workhorse singleton
  - Scans local disk on startup to find installed models
  - Manages `URLSession`-based downloads with resume data support
  - Retry logic with exponential backoff (2s → 4s → 8s, max 3 attempts) for transient network errors
  - Writes `models.ini` for llama-server's Router Mode whenever the model list changes
  - Sanity-checks downloads (rejects files under 1 MB as likely garbage responses)
- `ActiveDownload.swift`: tracks in-progress `URLSessionDownloadTask` instances and aggregate `Progress`
- `DownloadError.swift`: typed errors — incompatible hardware, insufficient disk space, etc.

### `System/` — Server Lifecycle
- `LlamaServer.swift`: launches/stops/reloads the `llama-server` binary as a child `Process`
  - Runs in **Router Mode** using `--models-preset models.ini` and `--models-max 1`
  - Health-gates status polling: waits for `/health` to succeed before beginning `/models` polls
  - Polls `/models` every 1 second to track loaded/loading/unloaded state; logs load/unload transitions
  - `activeModelPath` is a **computed property** derived from `modelStatuses` — always consistent with poll state
  - Monitors RAM usage via macOS `footprint` tool, reported every 2 seconds
  - Graceful shutdown: `SIGTERM` then `SIGKILL` after 2 seconds if needed
  - Sets `GGML_METAL_NO_RESIDENCY=1` env var (Metal GPU memory management hint)
  - Supports optional `--sleep-idle-seconds` to unload models after inactivity
  - Supports optional `--host` for network exposure beyond localhost
  - Starts/stops `MemoryPressureMonitor` alongside the server process lifecycle
- `LlamaServerAPI.swift`: HTTP client for the llama-server REST API
  - All requests use `127.0.0.1` (not `localhost`) to avoid macOS IPv6 probe noise
  - `GET /health` — readiness check (`isReady()`) used by startup gate
  - `GET /models` — fetch all model statuses
  - `POST /models/load` — request a model load
  - `POST /models/unload` — unload a model
  - `GET /props` — check if a model is sleeping
- `MemoryPressureMonitor.swift`: kernel push notification subscriber for system memory pressure
  - Zero polling overhead — `DispatchSource.makeMemoryPressureSource`, no timers
  - On `.critical`: waits up to 5s for in-flight generation, then unloads active model
  - 60-second cooldown suppresses repeated actions during sustained pressure
  - Posts `LBMemoryPressureDidOccur` notification for UI
- `SystemMemory.swift`: reads available unified memory for compatibility checks
- `DiskSpace.swift`: checks free disk space before initiating downloads
- `LaunchAtLogin.swift`: registers the app as a login item via `SMAppService`

### `Menu/` — UI
- `MenuController.swift`: root AppKit `NSMenu`/popover controller, opens on status bar icon click
- `ModelItemView.swift`, `FamilyItemView.swift`, `ItemView.swift`: per-model and per-family rows
  - `ModelItemView` hover buttons: load (play.circle), copy ID, delete
- `ExpandedModelDetailsView.swift`: expanded detail panel for a selected model (size, context, memory estimate)
- `ModelActionHandler.swift`: bridges menu interactions to `ModelManager` and `LlamaServer` calls
- `HeaderView.swift`, `FooterView.swift`, `NavigationItems.swift`: menu chrome (server status, settings link, quit)
- `WelcomePopover.swift`: first-launch onboarding
- `Theme.swift`, `Layout.swift`, `Formatters.swift`: styling constants, sizing, human-readable number formatting

### `Settings/`
- `UserSettings.swift`: persisted preferences via `UserDefaults`
  - Models storage folder (custom path support)
  - Sleep/idle timer configuration
  - Network bind address (for LAN exposure)
  - Launch at login toggle
- `SettingsWindow.swift`: the settings panel, opened via `LBShowSettings` notification or `⌘,`

### `Common/`
- `Logging.swift`: shared `os.log` subsystem identifier
- `Notifications.swift`: all `Notification.Name` constants (`LBServerStateDidChange`, `LBModelDownloadsDidChange`, `LBMemoryPressureDidOccur`, etc.)
- `Clipboard.swift`: paste helper utility

---

## Data Flow Summary

```
User clicks menu → ModelActionHandler
  → ModelManager.downloadModel()     → URLSession → Hugging Face
  → ModelManager.updateModelsFile()  → writes models.ini to disk
  → LlamaServer.reload()             → kills + restarts llama-server process
  → LlamaServer.loadModel()          → POST /models/load/{id}
  → status polling reads /models every 1s
  → NotificationCenter → UI updates (MenuController, ItemViews)
```

---

## The `llama-cpp/` Folder — Metal, not MLX

The bundled binaries are **native llama.cpp compiled for Apple Silicon with Metal GPU acceleration** — not Apple MLX.

| Binary | Purpose |
|---|---|
| `llama-server` | HTTP inference server (OpenAI-compatible API), version b8165 (see `llama-cpp/version.txt`) |
| `libllama.0.dylib` | Core llama.cpp inference engine |
| `libggml.0.dylib` | GGML tensor library core |
| `libggml-base.0.dylib` | GGML base operations |
| `libggml-metal.0.dylib` | Metal GPU compute backend |
| `libggml-cpu.0.dylib` | CPU fallback backend |
| `libggml-blas.0.dylib` | Accelerate/BLAS matrix ops |
| `libggml-rpc.0.dylib` | Remote procedure call backend |
| `libmtmd.0.dylib` | Multimodal (vision) support |

**MLX** is Apple's separate ML framework (used by projects like `mlx-lm`). LlamaBarn does **not** use MLX. The choice is intentional — as of late 2025, llama.cpp's GGML+Metal performance is competitive with MLX on Apple Silicon (per contributor astoilkov), and llama.cpp's `llama-server` provides the Router Mode architecture the whole app depends on. Adding MLX would require a different model format (not `.gguf`) and a parallel server architecture.

---

## Key Design Decisions

- **Router Mode**: A single persistent `llama-server` process handles all models. Models are loaded/unloaded on demand via API rather than restarting the server each time.
- **`models.ini`**: Declarative config file generated from the installed model list. llama-server reads this at startup to know what models are available and how to configure them.
- **NotificationCenter-driven UI**: All state changes (server status, model status, downloads) propagate via `NotificationCenter`, keeping the menu UI decoupled from the backend.
- **`@MainActor` isolation**: `LlamaServer` and `ModelManager` are both `@MainActor`-isolated singletons, simplifying state management while offloading heavy I/O to background tasks.
- **Memory-first compatibility**: Before a download starts, the app checks both available disk space and whether the model's estimated runtime memory fits within the system's unified memory budget.

---

## Fork-Specific Changes

### Memory Optimization Flags (`LlamaServer.swift`) — `personal/memory-optimizations`
Three flags are appended unconditionally to the llama-server `arguments` array at launch (see `specs/memory-optimization-24gb.md`):
- `-fa on` — Flash Attention, reduces peak VRAM during prompt prefill
- `-ctk q8_0` — 8-bit Key cache quantization (~50% KV cache memory reduction)
- `-ctv q8_0` — 8-bit Value cache quantization (required for stability on 24GB hardware)

Verify at runtime: `ps aux | grep llama-server`

### Upstream PR Candidates (`dev`, branches cut from `main`)

| Branch | Change | Spec |
|---|---|---|
| `feat/fix-ipv4-polling` | `127.0.0.1` base URL + `/health` startup gate | `specs/url-session-connection-reuse.md` |
| `feat/active-model-path-refactor` | `activeModelPath` as computed property, remove 7 write sites | `specs/active-model-path-refactor.md` |
| `feat/memory-pressure-monitor` | `MemoryPressureMonitor.swift` — kernel memory pressure → model unload | `specs/adaptive-context-scaling.md` |
| `feat/load-model-button` | Load (play.circle) button in menu hover actions | — |
| `feat/load-unload-logging` | Load/unload transition logging via status polling | — |

### Reduced Log Verbosity (`LlamaServer.swift`) — local only
`--log-verbosity 1` added to llama-server args to suppress verbose GGML/Metal init output.

### Build Script (`scripts/build-archive.sh`)
CLI alternative to Xcode's Archive + Export workflow:
```bash
./scripts/build-archive.sh [version]   # e.g. ./scripts/build-archive.sh 0.25.1
```
- Builds a Release archive and copies `.app` to `build/export/`
- Version passed as `MARKETING_VERSION` override — does not modify `project.pbxproj`
- Full build log written to `build/build.log`
- App version displays in footer as `<version> · llama.cpp <build>` (e.g. `0.25.1 · llama.cpp b8088`)

### Upgrading llama.cpp Binaries
1. Download the macOS arm64 tar.gz from the llama.cpp releases page
2. Extract into `llama-cpp/`, replacing existing files (`--strip-components=1`)
3. Remove extra binaries not used by LlamaBarn (keep only `llama-server`, dylibs, `version.txt`)
4. Update `llama-cpp/version.txt` to the new build tag
5. **Important**: Install from `build/archives/LlamaBarn.xcarchive/Products/Applications/` — not from `build/export/` — as `version.txt` is bundled into `Resources/` via the archive step. The `build/export/` copy from `cp -R` will show `llama.cpp unknown` if the archive step was skipped or stale.
