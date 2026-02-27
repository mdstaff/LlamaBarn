# Memory Optimization for 24GB Apple Silicon — Technical Spec

## Environmental Constraints

- **Hardware**: Apple Silicon MacBook Pro, 24GB Unified Memory
- **Target Models**: Qwen 3.5 27B+, Mistral Small 24B+ (GGUF Q4_K_M quantization)
- **Goal**: Maintain a ~20GB memory envelope to prevent macOS SSD swapping and preserve system responsiveness for dev tools (Xcode, VS Code)

The remaining ~4GB headroom is reserved for the OS, active dev tools, and browser tabs. Breaching this budget causes macOS to page memory to the SSD, which degrades both inference throughput and system responsiveness.

---

## Required llama.cpp CLI Arguments

These flags are applied globally at server launch in `LlamaServer.swift`. They are unconditional because the overhead cost is negligible on small models but critical for large ones.

| Flag | Value | Purpose |
|---|---|---|
| `-fa` | `on` | **Flash Attention** — reduces peak VRAM during prompt prefill by recomputing attention in tiles rather than materializing the full attention matrix. Also ensures O(n) rather than O(n²) memory scaling with context length. |
| `-ctk` | `q8_0` | **Key cache quantization** — quantizes the KV cache key tensor to 8-bit integers. Reduces KV cache memory footprint by ~50% versus FP16. |
| `-ctv` | `q8_0` | **Value cache quantization** — quantizes the KV cache value tensor to 8-bit integers. Required alongside `-ctk` for stability on high-parameter models within 24GB RAM; asymmetric quantization (keys only) can cause numerical instability at long contexts. |

### Memory Impact (illustrative, Q4_K_M, 4096 context)

| Model | Without flags | With flags | Savings |
|---|---|---|---|
| Mistral Small 24B | ~20.5 GB | ~16.8 GB | ~3.7 GB |
| Qwen 3.5 27B | ~22 GB | ~18 GB | ~4 GB |

Estimates based on community benchmarks. Actual usage varies by context length and batch size.

---

## Implementation

### Location

`LlamaBarn/LlamaBarn/System/LlamaServer.swift` — `start()` method, `arguments` array construction (around line 157).

### Applied flags

```swift
// Memory optimization for large models on 24GB Apple Silicon
// See specs/memory-optimization-24gb.md
arguments.append(contentsOf: ["-fa", "on", "-ctk", "q8_0", "-ctv", "q8_0"])
```

These flags are appended unconditionally after the base arguments. Flash Attention and 8-bit KV cache quantization have no meaningful downside on smaller models and are essential for 24B+ models to fit within the 20GB target envelope.

### Pre-execution guard (large models)

The model load path in `LlamaServer.loadModel()` has no per-model argument injection point — llama-server's Router Mode accepts per-model config only via `models.ini`. The global flags above cover the critical case. If per-model overrides are needed in future, the `serverArgs` field on `CatalogEntry` and `ModelManager.updateModelsFile()` are the correct extension points.

**15GB threshold note**: Models with `fileSize > 15_000_000_000` bytes (approximately 15GB on disk) are the primary risk class on 24GB hardware. The global flags are always active, so no runtime branching is needed. If this changes (e.g. a future toggle in Settings), the check should be `model.fileSize > 15_000_000_000`.

---

## Reference

- Upstream PR: https://github.com/ggml-org/LlamaBarn/pull/34
- llama.cpp Flash Attention docs: `--flash-attn` / `-fa` flag in llama-server `--help`
- KV cache quantization: `-ctk` / `-ctv` flags, supported types: `f32`, `f16`, `q8_0`, `q4_0`, `q4_1`, `iq4_nl`, `q5_0`, `q5_1`
