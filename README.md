# Jack

Drop photos → get one resized PDF. A signed, native drag-and-drop tool for **macOS and Windows**
that replaces fiddly resize-then-combine workflows with a single drag.

## What it does (both platforms)
- Accepts dropped images (JPEG, PNG, TIFF, …; macOS also HEIC) — or run with no files to pick.
- Resizes each to **1600 px on the long edge** (honors EXIF orientation; never upscales).
- Re-encodes at JPEG quality 72, merges into **one PDF**, sorted naturally by filename.
- Saves to the Desktop as `Jack_<timestamp>.pdf` and reveals it in Finder / Explorer.
- **Never modifies the originals.**

Tune `MaxEdge` / quality at the top of `Sources/main.swift` (mac) and `win/Jack/Program.cs` (win).

## macOS — native Swift droplet
Swift / AppKit · ImageIO (resize) · PDFKit (merge). Built + signed + notarized locally:
```bash
./build.sh      # universal arm64+x86_64, Developer ID sign (hardened runtime + timestamp)
./notarize.sh   # Apple notary submit + staple  (see script header for credentials)
```
Output `build/Jack.app`. Icon rendered by `Sources/makeicon.swift` (CoreGraphics) → `iconutil`.

## Windows — native .NET exe
.NET 8 / WinForms · System.Drawing (resize) · PdfSharp (merge). A single self-contained
signed `.exe` — ideal for PDQ fleet deployment. Built + signed in CI on every `v*` tag
(`.github/workflows/release.yml`) via **Azure Trusted Signing** (cert in the cloud, no key in CI).

## Release flow
1. `./build.sh && ./notarize.sh`, zip `Jack.app`.
2. `gh release create vX.Y.Z Jack-mac-*.zip` — this tags the commit.
3. The tag triggers CI, which builds + signs `Jack-win-x64.exe` and attaches it to the same release.

## Brand
Navy `#0A2540` · Teal `#0E6E6E`→`#14B8A6` · Amber `#F5A623` · Page white. © ThinkOpen Inc.
Bundle id `net.thinkopen.jack`.
