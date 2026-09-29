# Launcher

<img src="Resources/logo.svg" alt="Launcher" width="64" height="64">

A dependency-free macOS launcher, clipboard history, window tiler, translator, and screenshot tool built with Swift and AppKit. Requires macOS 26 or later.

`make install` builds and opens `/Applications/Launcher.app` and registers it as a login item. `make uninstall` removes it, `make dmg` writes a disk image to `.local/dist`, and `make check` runs the tests. Pasting, translating selections, tiling, and window search need Accessibility access.

| Shortcut | Action |
|---|---|
| ⌘Space | Launcher |
| ⌘⇧V | Clipboard history |
| ⇧⌥; / ⇧⌥' | Tile window left / right; repeat to cycle 1/2, 2/3, 1/3, full |
| ⇧⌥[ / ⇧⌥] | Move window to previous / next screen |
| ⌥D / ⌥A | Translate selection / open empty translator |
| ⌃⌘A | Capture an area or window |

The launcher lists apps, Finder, and System Settings panes. Search matches exact, prefix, and word-prefix, then ranks by usage; launching learns the typed query as an alias. List bundle identifiers in `hidden.json` to hide entries.

When a running app has multiple windows, on every Space, they are searchable by title and listed below the app's row; selecting one switches to that window. Open Google Chrome tabs are searchable by title and site and listed below Chrome's row in place of its windows; selecting one switches to that tab, and macOS asks once for permission to control Chrome. Combe tabs are listed the same way in place of its windows. Window discovery uses private macOS APIs and may need updates after macOS changes.

The clipboard panel keeps text and images for 48 hours, skips concealed clips, and pastes with Return or ⌘1–⌘9.

Screenshots need Screen & System Audio Recording access. Press ⌃⌘A, choose Area to drag a selection or Window to click a highlighted window. Drag inside the selection to move it, or drag its handles to resize. The glass toolbar switches between Area, Window, and Scroll. Copy captures the selection directly into clipboard history. For scrolling captures, select Scroll, keep fixed headers, sidebars, and scrollbars outside the selection, then click Start. Hold still until the first frame settles; scroll down slowly and pause between movements. The live preview shows the accepted content. Finish checks the final frame and copies the PNG directly into clipboard history. Cancel discards the capture. The area must stay visible and stationary. Captures stop growing at 40 million pixels. Missing overlap, upward scrolling, animations, and ambiguous repeating content can prevent stitching; scroll back to the last accepted position before continuing.

Translation uses any OpenAI-compatible endpoint configured in `translate.json`:

```json
{
  "base": "https://api.openai.com/v1",
  "key": "sk-...",
  "model": "gpt-4o-mini",
  "extra": {},
  "styles": [
    { "name": "Plain", "prompt": "Translate between Chinese and English." },
    { "name": "Sharp", "prompt": "Translate concisely.", "model": "gpt-4o", "extra": { "reasoning_effort": "low" } }
  ]
}
```

Only `key` is required; `base` and `model` default to DeepSeek. `extra` is merged into the request body, and a style's `model` and `extra` override the top-level ones.

Data lives in `~/Library/Application Support/Launcher`: `aliases.json`, `usage.json`, `hidden.json`, `translate.json`, and `clipboard/`.
