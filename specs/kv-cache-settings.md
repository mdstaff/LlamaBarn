# KV Cache Quantization Settings — Spec & Upstream Discussion Primer

> **Status: Implemented in `dev`** — separate K and V cache pickers in Settings, defaults of
> `-ctk f16 -ctv q8_0`. Ready for upstream Discussion.

---

## Background

Earlier versions of this fork hardcoded `-ctk q8_0 -ctv q8_0` for both caches (see
`specs/memory-optimization-24gb.md`). Community research (summarised below) has since made clear
that treating K and V as a single entity is suboptimal — the two caches have meaningfully different
sensitivity profiles that warrant independent control.

---

## The K/V Split: Why It Matters

### Value (V) Cache — resilient

The V-cache stores the actual semantic payload delivered forward through the model's residual
stream. Because the final attention output is a weighted *summation* of Value vectors across
multiple heads and sequence positions, quantization noise tends to cancel out — positive and
negative errors average toward zero during the inner product computation. q8_0 introduces roughly
5% noise per value, but that noise is benign in aggregate.

**Recommendation: q8_0** — roughly 50% memory reduction over f16 with negligible quality loss.
q4_0 is available for extreme memory pressure but may affect output quality at long contexts.

### Key (K) Cache — fragile

The K-cache doesn't store semantic payload; it stores *routing and addressing logic*. Keys are
matched against the current Query via dot product to determine attention scores, which are then
passed through a softmax (an exponential function). Even small precision errors in Keys are
amplified exponentially by softmax, risking redirection of attention to entirely wrong tokens —
not merely degrading quality, but corrupting the model's positional map entirely.

**Why post-RoPE quantization makes this worse:** Modern inference engines (including llama.cpp)
quantize Keys *after* Rotary Position Embeddings have been applied. RoPE encodes position by
rotating Key vectors in a high-dimensional complex plane, with high-frequency components (rotating
~1 radian/token) responsible for fine-grained local distinctions. Quantizing post-rotation
destroys these high-frequency components. At 30k+ tokens, small quantization errors accumulate
into large angular errors — the model "knows" a tool or variable exists but its keys are too
noisy to locate it reliably.

The structurally correct fix would be to quantize Keys *before* RoPE rotation, then dequantize
before applying embeddings — preserving angular precision. Current llama.cpp architecture doesn't
support this. Until it does, f16 is the only safe K-cache format for complex workloads.

**Recommendation: f16.** Manifestations of K-cache degradation include hallucinations, infinite
tool-calling loops, and malformed structured output (especially JSON) — most visible in coding
and agentic workloads at deep contexts.

### Empirical benchmarks

At 40k–72k token contexts with `-ctk q4_0 -ctv q4_0`:
- **80% spike** in malformed tool calls and logic loops vs. unquantized baseline
- Lowering K-cache from f16 → q8_0 introduces minor token flips; dropping to q4_0 **breaks
  multi-turn reasoning** capabilities

Throughput data on large models (e.g. GPT-OSS 120B) with aggressive q4_0 KV:
- Prefill: 1,200 → 90 tokens/sec
- Generation: 35 → <10 tokens/sec

Removing KV quantization entirely and accepting higher VRAM usage keeps data in the GPU's native
FP execution pipeline and yields **order-of-magnitude throughput recovery**.

**Key principle:** It is better to run a *shorter* context with no KV quantization than a *longer*
context with aggressive quantization. A vast context window is computationally useless if the
routing mechanisms are too noisy to retrieve accurate data from it.

### Strategy reference

| Strategy | `-ctk` | `-ctv` | Context stability >30k | VRAM impact |
|---|---|---|---|---|
| Full precision | f16 | f16 | Excellent | Maximum |
| **Golden Compromise** *(our default)* | **f16** | **q8_0** | **Excellent** | **~25% reduction** |
| Aggressive asymmetric | q8_0 | q4_0 | Acceptable for basic chat | ~40% reduction |
| Uniform aggressive | q4_0 | q4_0 | Catastrophic (loops/fuzziness) | ~50% reduction |

---

## Model Architecture and Sensitivity

Architecture dictates tolerance more than any single rule of thumb.

### Dense transformers — Qwen 2.5/3 (highest sensitivity)

Qwen's high-density feature representations mean quantization noise compounds *multiplicatively*
rather than averaging out — the noise cancellation that protects other models simply doesn't
occur. At depth, attention scores collapse into high-entropy noise and the model loses track of
conversational state, formatting rules, and instruction logic. **K-cache must remain at f16.**
Even q8_0 on the K-cache causes tool-calling loops in Qwen3-Coder at depth.

### Gemma 3 — resilient in theory, CPU-bottlenecked in practice

Gemma 3 uses interleaved sliding window attention (5 local layers : 1 global layer). Local layers
only attend to a 1,024-token window, so they're naturally immune to long-range angular drift.
This cuts the total KV footprint by ~45% and makes Gemma 3 *mathematically resilient* to KV
quantization — users report clean 128k-context performance with q4_0 K+V.

**However**, the novel SWA architecture currently lacks optimized quantized Flash Attention kernels
in llama.cpp, triggering silent CPU fallback when quantized KV caches are used. This is a
software bug masquerading as quality sensitivity — throughput craters to single digits not because
output quality suffers, but because the workload routes through the CPU memory bus. Watch for this
if Gemma 3 is ever added to the LlamaBarn catalog.

### Nemotron-30B (Mamba-2 / MoE hybrid — lowest sensitivity)

Of 42 total layers, only ~4 are standard self-attention layers; the rest are Mamba SSM or MLP
layers. Mamba layers maintain a compact evolving hidden state rather than a growing KV cache, so
the cumulative KV footprint is a fraction of a comparable dense model. Result: q4_0 K+V at 100k+
tokens with virtually zero measurable perplexity loss. Community benchmarks report >100 tokens/sec
on Apple M4 Max and a 3.3x throughput advantage over comparable MoE Transformers in long-context
benchmarks.

### Architecture summary

| Architecture | Example | Attention layers / total | KV dependence | Q4 K-cache safe? |
|---|---|---|---|---|
| Dense transformer | Qwen 2.5/3 Coder | 100% | Critical | No — coherence failure |
| Standard dense | LLaMA 3.1 8B | 100% | High | Marginal |
| Hybrid Mamba-MoE | Nemotron-30B | ~10% (4 of 42) | Minimal | Yes |
| Interleaved SWA | Gemma 3 27B | 100% (5:1 local/global) | Moderate (−45%) | Yes (quality-wise; CPU fallback risk) |

---

## CPU Bottleneck: The Hidden Performance Trap

Quantized KV caches require on-the-fly dequantization before the attention computation. Modern
GPUs handle this efficiently via fused kernels — but only when the inference engine has
hardware-specific kernels for the exact combination of cache format + attention implementation.

If Flash Attention (`-fa on`) lacks a compatible kernel for the quantized layout on the current
backend (Metal, SYCL, etc.), llama.cpp silently falls back to CPU dequantization:

- GPU memory bandwidth: ~1 TB/s
- CPU/system RAM bandwidth: ~80 GB/s

At 100k+ token contexts the cache is tens of gigabytes; routing that through the CPU memory bus
stalls the entire pipeline. The GPU idles while the CPU struggles to keep up.

**Practical check:** If enabling KV quantization causes throughput to drop dramatically rather
than improve, inspect logs for CPU fallback. The engine may be silently accepting the `-ctk`/
`-ctv` flags while executing the heaviest workload on the CPU.

---

## Forward Look: Beyond `-ctk`/`-ctv`

The flat per-cache precision flags are a first step. Emerging techniques worth tracking:

- **Hadamard pre-quantization transforms** — smooth outlier activations across cache dimensions
  before quantizing, recovering precision specifically in the sensitive K-cache
- **KVTC (KV Tensor Compression)** — exploits low-rank structure in KV tensors for up to 8×
  footprint reduction without scalar precision truncation
- **Progressive Mixed-Precision KV (PM-KVQ)** — allocates higher precision to recent and
  structurally sensitive tokens, down-casting older stable context aggressively; improves
  reasoning benchmarks ~8% under equal memory budgets vs. static quantization

---

## Implementation (this fork)

- `UserSettings.keyCacheType` — defaults to `.f16`
- `UserSettings.valueCacheType` — defaults to `.q8_0`
- Both exposed as separate pickers in Settings under **K Cache** / **V Cache**
- `LlamaServer.start()` passes `-ctk <keyCacheType> -ctv <valueCacheType>` at launch
- Changing either setting posts `LBUserSettingsDidChange`, which triggers `LlamaServer.reload()`
  (a full llama-server restart) if a model is currently loaded

---

## Open Question: Restart Notification

**Should the user be notified when a settings change causes the server to restart?**

Currently a settings change silently restarts llama-server. This is fine when the app is idle,
but is potentially disruptive when:

- A chat session is in progress in a connected client (e.g. an IDE, OpenClaw, Continue)
- A long generation is running
- The model is mid-load

The restart tears down the active llama-server process, terminating any in-flight HTTP connections.
Connected clients will receive a connection error with no explanation.

### Options to consider

| Option | Pro | Con |
|---|---|---|
| **Silent restart (current)** | Simple, no UI complexity | Client connections severed without warning |
| **Toast / menu bar notification** | Low friction, user is informed | Notification may be missed if client app is focused |
| **Confirmation dialog before restart** | Explicit user consent | Disruptive if user is just browsing settings |
| **Defer restart — apply on next model load** | Non-destructive, no active session impact | Setting appears changed but isn't in effect yet; could confuse users |
| **Warn only if a model is currently loaded** | Targeted — silent when idle | Adds a state check before every settings-triggered restart |

### Recommendation for upstream Discussion

Raise the **"warn only if a model is loaded"** option as the minimum viable approach:
a brief inline notice in the Settings UI (e.g. *"Changes take effect on next model load"* or
a banner: *"Restart required — model will reload"*) scoped to the moment a change is made
while the server is active. This avoids modal dialogs while still giving connected clients a
heads-up signal.

The broader question of whether LlamaBarn should emit a lifecycle event (notification, menu bar
badge, log entry) that external clients can observe is worth raising as a separate Discussion item.

---

## Upstream Discussion Draft

**Title:** Split K/V cache quantization controls + settings-triggered restart UX

**Body:**

We've been running a fork with configurable KV cache quantization and wanted to share findings
and open two related questions before cutting a PR.

**1. K and V caches warrant separate controls**

The community consensus is that K-cache is significantly more sensitive to precision loss than
V-cache. The core reason is post-RoPE quantization: llama.cpp quantizes Keys after the rotary
embeddings are applied, destroying the high-frequency components responsible for fine-grained
positional distinctions. At 30k+ tokens this produces large angular errors — empirically, an 80%
spike in malformed tool calls vs. an unquantized baseline at 40k–72k contexts with `-ctk q4_0`.
The V-cache stores semantic representations rather than routing data, so its quantization noise
averages out across heads and positions.

The practical sweet spot is `-ctk f16 -ctv q8_0` (the "Golden Compromise"): full angular
precision on Keys, ~50% VRAM reduction on Values. We'd like to propose a Settings UI with two
independent pickers defaulting to f16 / q8_0, with f16, q8_0, and q4_0 as options.

**2. Should settings-triggered restarts notify the user?**

When KV cache (or other server-level settings like sleep timer) change while a model is loaded,
`llama-server` must restart to apply them. Currently this happens silently. For users running
connected clients (IDEs, OpenClaw, etc.) this severs active connections without warning.

Should LlamaBarn surface a restart signal — inline settings banner, menu bar indicator, or
notification — when a settings change causes a live server to restart? And should we consider
deferring the restart to the next model load rather than applying it immediately?

Interested in maintainer preference before writing the PR.
