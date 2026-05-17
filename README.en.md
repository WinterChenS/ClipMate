[**中文**](README.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | English

# ClipMate - macOS Clipboard Manager

A high-fidelity clone of the macOS Paste app, built with native Swift 6 + SwiftUI/AppKit.

![ClipMate Preview](assets/screenshots/preview.jpg)

> ✅ **No Xcode required!** Build and package directly with `swift build` + `build.sh`. Supports both Apple Silicon and Intel Macs.

## Features

| Module | Feature | Status |
|--------|---------|--------|
| 📋 Clipboard Monitor | Real-time monitoring for text, images, files, links, and rich text | ✅ |
| 📜 History Panel | Horizontal scrolling card list, high-fidelity Paste UI, dominant color extraction | ✅ |
| 🔍 Full-text Search | FTS5 full-text index, 300ms debounce real-time search | ✅ |
| 📌 Pinboard | Pinned board with groups, color labels, right-click delete/rename | ✅ |
| ⭐ Favorites | Bookmark important clipboard entries | ✅ |
| ⌨️ Global Hotkey | ⌘⇧V to toggle panel (Carbon RegisterEventHotKey) | ✅ |
| 🚫 App Exclusion | Exclude sensitive apps like password managers | ✅ |
| ⚙️ Preferences | Launch at login / Dock icon / notifications / storage management / data export | ✅ |
| ☁️ iCloud Sync | iCloud Drive ubiquity container sync (requires Xcode signing) | ✅ |
| 🔐 Accessibility Detection | Auto-alert on permission loss, re-authorization guide after reinstall | ✅ |
| 🎨 App Icon | Menu bar + Dock icon, full-size icns | ✅ |

## Build & Run

### Option 1: build.sh One-Click Build (Recommended)

```bash
cd PasteClone

# Universal Binary (default, supports both M-series + Intel Macs)
./build.sh

# Apple Silicon only
./build.sh --arch arm64

# Intel Mac only
./build.sh --arch x86_64
```

Build artifacts are in the `.build/` directory:

| Artifact | Description |
|----------|-------------|
| `ClipMate-1.0.0-Universal.dmg` | Universal binary (default) |
| `ClipMate-1.0.0-ARM.dmg` | Apple Silicon only |
| `ClipMate-1.0.0-Intel.dmg` | Intel Mac only |

**Subcommands**:

```bash
./build.sh build       # Compile only
./build.sh bundle      # Compile + package .app + sign
./build.sh dmg         # Full pipeline (default)
./build.sh run         # Compile and run
./build.sh clean       # Clean build artifacts
```

### Option 2: Manual Build

```bash
# Release build
swift build -c release

# Run
.build/release/ClipMate
```

### Option 3: Xcode (requires Xcode + Developer Account)

```bash
open PasteClone.xcodeproj
# ⌘R to run
```

> ⚠️ iCloud sync requires building through Xcode with a valid Provisioning Profile. The `build.sh` build automatically removes iCloud entitlements to prevent launch failures.

## Dependencies

| Library | Version | Purpose |
|---------|---------|---------|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 6.29 | SQLite ORM + FTS5 full-text search |

## Technical Highlights

- **Clipboard Monitoring**: `NSPasteboard.changeCount` polling (0.5s interval), with exclusion rule support
- **UI**: `NSPanel` HUD frosted glass background + SwiftUI horizontal card gallery
- **Data**: GRDB + FTS5 full-text index, stored at `~/Library/Application Support/ClipMate/`
- **Global Hotkey**: Carbon `RegisterEventHotKey` API (⌘⇧V), LSUIElement mode
- **Multi-Architecture**: `swift build --arch` + `lipo -create` for Universal Binary
- **Code Signing**: PlistBuddy filters iCloud entitlements before codesign, preventing error 153
- **Swift 6**: Full `@MainActor` adoption for concurrency safety, strict concurrency mode

## System Requirements

- **Minimum**: macOS 14.0 (Sonoma)
- **Recommended**: macOS 15.0 (Sequoia)

## Permission Notice

On first launch, you need to grant accessibility permission in **System Settings > Privacy & Security > Accessibility**, otherwise the quick paste feature will not work. After reinstalling, you must remove the old entry first, then re-add it.

## License

MIT License
