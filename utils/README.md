# Goose iOS Utilities

This directory contains utility scripts used by the launch scripts in the parent directory.

## Contents

### tunnel_client.js

A Node.js client for connecting to a Cloudflare tunnel proxy service. This allows exposing a local `goosed` instance to the internet through Cloudflare's edge network.

**Dependencies:** Requires the `ws` (WebSocket) package, which is installed automatically by `launch_tunnel.sh`.

**Usage:**
```bash
node tunnel_client.js <worker-url> <agent-id> [target]
```

- `worker-url`: The Cloudflare Worker URL (default: https://cloudflare-tunnel-proxy.michael-neale.workers.dev)
- `agent-id`: A unique identifier for this tunnel connection
- `target`: The local service to proxy (default: http://127.0.0.1:8000)

**Example:**
```bash
node tunnel_client.js \
  https://cloudflare-tunnel-proxy.michael-neale.workers.dev \
  my-unique-id-abc123 \
  http://localhost:62998
```

This will create a publicly accessible URL at:
```
https://cloudflare-tunnel-proxy.michael-neale.workers.dev/tunnel/my-unique-id-abc123/
```

### package.json

Manages the Node.js dependencies for the utilities in this directory.

## Installation

Dependencies are automatically installed when you run `./launch_tunnel.sh`. If you need to install them manually:

```bash
cd utils
npm install
```

## Notes

- The tunnel service is a public, shared service - best effort only
- For production use, consider deploying your own Cloudflare Worker
- See the [cloudflare-tunnel-goosed](https://github.com/michaelneale/cloudflare-tunnel-goosed) repository for more details
