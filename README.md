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
2. `./dmg.sh` → signed + notarized + stapled `build/Jack-mac.dmg` (the file clients download).
3. `gh release create vX.Y.Z Jack-mac-*.zip build/Jack-mac.dmg` — this tags the commit.
   The zip feeds Sparkle auto-update; the DMG is the client install link:
   `https://github.com/jackarkcreator/jack/releases/latest/download/Jack-mac.dmg`
4. The tag triggers CI, which builds + signs `Jack-win-x64.exe` and attaches it to the same release.
5. `./intune.sh` → pushes `build/Jack-mac.dmg` to every Microsoft Intune tenant that deploys Jack as a
   managed app (or `./intune.sh vX.Y.Z` for a published release; `DRY=1` to preview). Managed Macs run
   Jack with Sparkle silenced, because standard users can't approve its admin prompt, so Intune is their
   update channel and this step is what upgrades them. The tenant list lives outside this repo.

## Brand
Navy `#0A2540` · Teal `#0E6E6E`→`#14B8A6` · Amber `#F5A623` · Page white. © ThinkOpen Inc.
Bundle id `net.thinkopen.jack`.
