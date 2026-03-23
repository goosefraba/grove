# Grove

A native macOS file browser — fast, minimal, keyboard-driven.

## Features

- **Tabbed browsing** — native macOS window tabs (Cmd+T)
- **Three-pane layout** — sidebar, file list, inspector
- **Full keyboard navigation** — all standard Finder shortcuts
- **Quick Look** — spacebar preview
- **Drag & drop** — copy/move files between folders and apps
- **Context menus** — right-click on files or empty space
- **Directory watching** — auto-refreshes when files change
- **Volume tracking** — sidebar updates on mount/unmount

## Requirements

- macOS 14.0+
- Xcode 15+ (for building)

## Run

```bash
./run.sh
```

Builds the project and launches the app.

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Cmd+T | New tab |
| Cmd+N | New window |
| Cmd+Shift+N | New folder |
| Cmd+C / Cmd+X / Cmd+V | Copy / Cut / Paste |
| Cmd+Delete | Move to Trash |
| Cmd+O / Cmd+Down | Open |
| Cmd+Up | Enclosing folder |
| Cmd+[ / Cmd+] | Back / Forward |
| Space | Quick Look |
| Enter | Rename |
| Cmd+Shift+. | Toggle hidden files |
| Cmd+Option+I | Toggle inspector |
| Cmd+A | Select all |

## License

Private.
