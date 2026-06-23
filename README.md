# Jack

Drop photos → get one resized PDF. A signed, native macOS droplet that replaces
GRU's two legacy Automator apps ("Photo Resize" + "PDF Creator") with a single drag.

## What it does
- Accepts dropped images (JPEG, PNG, HEIC, TIFF, …) — or double-click to pick.
- Resizes each to **1600 px on the long edge** (honors EXIF orientation; never upscales).
- Re-encodes at JPEG quality 0.72, merges into **one PDF**, sorted by filename.
- Saves to `~/Desktop/Jack_<timestamp>.pdf` and reveals it in Finder.
- **Never modifies the originals.** (The old app overwrote them in place.)

Tune `MAX_EDGE` / `JPEG_QUALITY` at the top of `Sources/main.swift`.

## Build
```bash
./build.sh      # compile universal (arm64+x86_64), render icon, assemble, Developer ID sign
./notarize.sh   # submit to Apple notary + staple (needs credentials — see script header)
```

Output: `build/Jack.app`. Until notarized it runs on the build machine but is blocked
when transferred to other Macs (Gatekeeper: "Unnotarized Developer ID").

## Stack
Swift / AppKit droplet · ImageIO (resize) · PDFKit (merge). No external dependencies.
Icon is rendered from `Sources/makeicon.swift` (CoreGraphics) → `iconutil` .icns.

## Brand
Navy `#0A2540` · Teal `#0E6E6E`→`#14B8A6` · Amber `#F5A623` · Page white.
Bundle id `net.thinkopen.jack`. © ThinkOpen Inc.
