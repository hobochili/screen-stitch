# Screen Stitch

A small macOS app that joins screen recordings in the order they were recorded and compresses them into one MP4.

Requires macOS 14+ on Apple Silicon and Homebrew's `ffmpeg` (`brew install ffmpeg`).

## Use

- Drop `.mov`/`.mp4` files on the window or on the Dock icon, or click **+**.
- Clips are sorted by when they were recorded: the QuickTime `creationdate` tag, then `creation_time`, then the file's
  creation date. Drag rows to reorder; **⇅** re-sorts by date.
- Pick **Size** and **Quality**, then **Combine & Compress…**, and choose where to save the result.

**Size** caps the short side (1080p turns a 3456×2234 Retina recording into 1670×1080) and never upscales. The largest
clip sets the frame size, and clips with a different shape are letterboxed. **Quality** is the x264 CRF:
High 20, Standard 23, Small 28.

Output is H.264 + AAC with `+faststart`. Variable frame rate is kept, so static stretches cost almost nothing. If any
clip has audio, the others get silence. Clips with several audio tracks (mic + system) are mixed together.

## Build

```sh
./build.sh            # → build/Screen Stitch.app
./build.sh --install  # also copies it into ~/Applications
```

This needs only the Command Line Tools (`xcode-select --install`); full Xcode isn't required. The CLT don't ship the
SwiftUI macro plugin, so the code avoids `@State` and keeps view state on the `@Observable` model.

The app isn't notarized, so a copy built on one Mac and moved to another is blocked on first launch. Allow it under
System Settings → Privacy & Security → **Open Anyway**, or build it on that Mac instead.

## Command line

The same binary runs headless:

```sh
"$HOME/Applications/Screen Stitch.app/Contents/MacOS/ScreenStitch" --cli \
  [--size original|1440|1080|720] [--quality high|standard|small] OUTPUT.mp4 INPUT...
```
