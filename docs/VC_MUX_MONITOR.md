# vc-mux Monitor

`vc-mux-monitor` is a passive macOS status-bar observer for a running `vc-mux`
Unix socket. It connects as an idle client, reads JSON-RPC notifications that
the mux fans out, and never sends requests to the underlying MCP server.

Build it on macOS:

```bash
zig build mux-monitor -Demit-macos-app=false
```

Run the tray observer:

```bash
zig-out/bin/vc-mux-monitor --socket /tmp/mcp-brave.sock
```

For smoke tests and CI-style checks, use the headless observer:

```bash
zig-out/bin/vc-mux-monitor --socket /tmp/mcp-brave.sock --headless --once --timeout 5
```

The icon state is:

- orange: connecting or reconnecting
- green: connected and idle
- yellow: recently received a fanned-out notification
- red: disconnected; the monitor will retry automatically

The smoke test can run directly against a mock mux socket:

```bash
python3 tools/vc-mux-monitor/smoke_test.py zig-out/bin/vc-mux-monitor
```

For the full observer path, pass the `vc-mux` and mock MCP server binaries. The
script starts `vc-mux`, connects the monitor as a passive observer, sends a
`fanout` request from a separate client, and verifies that the monitor reports
the fanned-out `server/notice` notification:

```bash
python3 tools/vc-mux-monitor/smoke_test.py \
  zig-out/bin/vc-mux-monitor \
  /tmp/vc-mux \
  /tmp/vc-mux-mock-server
```
