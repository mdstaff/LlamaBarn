# Polling Startup Gate — Technical Spec

## Problem

Status polling starts immediately after `process.run()` succeeds, but llama-server
takes several seconds to initialize before it accepts HTTP connections. During this
window, every poll attempt generates `nw_socket_handle_socket_event SO_ERROR [61:
Connection refused]` log noise from the Apple network stack.

A dedicated `URLSession` with `httpShouldUsePipelining` was attempted as a fix but
made things worse — llama-server closes connections after each response, so pipelining
caused every subsequent poll to fail even after the server was ready.

## Solution

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

- `LlamaBarn/System/LlamaServerAPI.swift` — `isReady()` added
- `LlamaBarn/System/LlamaServer.swift` — `startStatusPolling()` gated on `isReady()`
