# Install the Safari Screensaver

The self-driving safari runs as a native screensaver — the same Zig core as the [browser version](/driving), drawn by a software rasterizer instead of the canvas. Grab the build for your platform below.

## Windows

[Download safari-windows.scr →](/downloads/safari-windows.scr)

Right-click the downloaded file and choose **Install** (on Windows 11, click "Show more options" first). That opens the Screen Saver settings dialog with it already selected — set your idle timeout and you're done. Or drop it in `C:\Windows\System32` to have it listed in the dropdown by name.

**Test** in that dialog runs it fullscreen; any key or mouse move exits. It's a self-contained 64-bit executable — no installer, no dependencies.

## Linux

[Download safari-linux →](/downloads/safari-linux)

A dynamically-linked X11 binary — it needs `libX11` and `libXrender`, both standard on any desktop with an X session. Make it executable and run it:

```
chmod +x safari-linux
./safari-linux
```

Controls: **space** pauses · **↑ / ↓** step a single frame · **J** jumps to the next intersection · **Q** or **Esc** quits.
