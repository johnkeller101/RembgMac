# RembgMac

A macOS menu bar app that runs [rembg](https://github.com/danielgatis/rembg) (AI background removal) as a local HTTP server.

RembgMac manages a bundled Python virtual environment with rembg installed, providing a lightweight way to serve background removal over HTTP on Apple Silicon Macs.

## Features

- **Menu bar app** -- no dock icon, just a status indicator (green/red/orange)
- **Bundled Python venv** -- creates and manages its own virtual environment, no global Python pollution
- **Auto-start** -- launches at login and starts the rembg server automatically
- **Process management** -- monitors the rembg process, auto-restarts on crash with exponential backoff
- **Health checking** -- periodic health checks with visual status in the menu bar
- **Request counting** -- tracks how many images have been processed
- **Log viewer** -- built-in window to view rembg server output
- **Model warm-up** -- sends a warm-up request on startup to pre-download the AI model

## Requirements

- macOS 13.0+
- Python 3 (via Xcode Command Line Tools or Homebrew)
- ~500MB disk space (Python venv + ONNX model)

## Installation

1. Open `RembgMac.xcodeproj` in Xcode
2. Build (Cmd+B)
3. Copy `RembgMac.app` from build products to `/Applications/`
4. Launch the app -- it appears in the menu bar

## First Launch

1. Click the menu bar icon (red circle)
2. Click **Setup** -- this creates a Python venv and installs rembg (~2-3 minutes)
3. The server starts automatically when setup completes
4. macOS may prompt to allow incoming network connections -- click **Allow**

## Usage

The rembg HTTP server listens on `http://0.0.0.0:7000` and accepts the standard rembg API:

```bash
# Remove background from an image
curl -X POST http://localhost:7000/api/remove \
  -F "file=@input.jpg" \
  -o output.png

# With a specific model
curl -X POST http://localhost:7000/api/remove \
  -F "model=birefnet-general-lite" \
  -F "file=@input.jpg" \
  -o output.png
```

Any application on the local network can reach the server at `http://<your-mac-ip>:7000`.

## Menu Bar

| Icon Color | Meaning |
|-----------|---------|
| Green | Server running and healthy |
| Orange | Starting, downloading model, or setting up |
| Yellow | Server unhealthy (process alive but not responding) |
| Red | Server stopped |

## Data Locations

- **Virtual environment**: `~/Library/Application Support/RembgMac/venv/`
- **Logs**: Viewable via the "View Logs" menu item

## License

MIT
