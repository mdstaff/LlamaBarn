# Polling Startup Gate & IPv4 Fix — Technical Spec

## Problem

Two sources of `nw_socket SO_ERROR [61: Connection refused]` log noise:

1. **Startup noise**: Status polling starts immediately after `process.run()` succeeds,
   but llama-server takes several seconds to initialize. Every poll attempt during this
   window generates connection refused errors from the Apple network stack.

2. **Per-request noise**: `localhost` resolves to `::1` (IPv6) first on macOS. llama-server
   only listens on IPv4 (`127.0.0.1`), so every request generates an IPv6 probe error before
   falling back to IPv4 — even after the server is fully ready.

A dedicated `URLSession` with `httpShouldUsePipelining` was attempted for problem 1 but
made things worse — llama-server closes connections after each response, so pipelining
caused every subsequent poll to fail even after the server was ready.

## Solution

Two changes, both in `feat/fix-ipv4-polling`:

### 1. Use `127.0.0.1` instead of `localhost`

In `LlamaServerAPI.swift`, change `baseUrl` to use `127.0.0.1` explicitly:

```swift
private var baseUrl: String { "http://127.0.0.1:\(port)" }
```

This eliminates the IPv6 probe on every request.

### 2. Gate the poll loop on a `/health` readiness check

Gate the poll loop on a `/health` check before beginning status polling. The loop
retries every 500ms until the server responds, then begins normal 1-second polling.

```swift
// Wait for llama-server to be ready before polling.
while !Task.isCancelled && !(await api.isReady()) {
  try? await Task.sleep(nanoseconds: 500_000_000)
}
// Poll /models to detect status.
while !Task.isCancelled {
  await checkStatus()
  try? await Task.sleep(nanoseconds: 1_000_000_000)
}
```

```swift
// In LlamaServerAPI:
func isReady() async -> Bool {
  await get(endpoint: "health", timeout: 1.0) != nil
}
```

## Why /health

llama-server's `/health` endpoint is lightweight, public (no API key required), and
returns a non-200 status while the server is still initializing — making it the
correct readiness signal before beginning heavier `/models` polling.

## What This Does NOT Fix

llama-server closes connections after each response (no persistent keep-alive from
the server side). Each poll will still create a new TCP connection — but since polling
only begins once the server is ready, those connections will succeed cleanly with no
log noise.

## File References

- `LlamaBarn/System/LlamaServerAPI.swift` — `isReady()` added, `baseUrl` changed to `127.0.0.1`
- `LlamaBarn/System/LlamaServer.swift` — `startStatusPolling()` gated on `isReady()`
