# Frosty

A Dock replacement for macOS that keeps the clutter in groups, the way Ice keeps
the menu bar tidy. Swift/AppKit + SwiftUI, macOS 14+, no special permissions.

It hides the real Dock by setting it to auto-hide with a 1000-second reveal delay,
then draws its own bar at the bottom of the main display.

## If the Dock ever stays hidden

Quitting Frosty from its ❄︎ menu-bar icon, `kill`, Ctrl-C and logging out all put
the original Dock settings back. A hard crash can't, so the originals wait in
`~/Library/Application Support/Frosty/dock-original.json` and are restored on the
next launch-and-quit. To bring the Dock back by hand:

```sh
defaults delete com.apple.dock autohide-delay; killall Dock
```

(This leaves auto-hide on, which is how this Mac had it before Frosty.)

## Build, test, run

```sh
xcodegen generate
xcodebuild -project Frosty.xcodeproj -scheme Frosty -derivedDataPath build test
open build/Build/Products/Debug/Frosty.app
```

The test target is deliberately not hosted by the app: a hosted run would launch
Frosty and hide the Dock. It compiles `Frosty/Model/` directly instead.

## Using it

- **Bar:** placed apps in config order, then a separator, then running apps that
  aren't placed. An app inside a group never appears loose; the group's dot lights up.
- **Right-click an app:** Hide · Quit · Keep in / Remove from Frosty · Move to Group
  (existing or New Group…) · Remove from group · Show in Finder.
- **Right-click a group:** Rename… · Ungroup.
- **Menu-bar ❄︎:** Hide the Real Dock · Auto-hide Frosty · Edit Config… · Reload
  Config · Quit.

## Config

`~/Library/Application Support/Frosty/config.json`, seeded on first launch from
the real Dock's pinned apps:

```json
{ "autoHide": true, "iconSize": 48,
  "items": [ { "app": "com.apple.finder" },
             { "group": "Tools", "apps": ["com.cx.onyx", "com.cxtasks.app"] } ],
  "icons": { "md.obsidian": "~/Library/Application Support/obsidian/icon.png" } }
```

`icons` (optional) swaps an app's icon for any image file. Use it for apps that
change their Dock icon at runtime, like Obsidian's *Appearance → App icon*: that
swap reaches only the Dock, and every public API still returns the icon inside
the `.app`.

Edit it, then choose Reload Config. Reordering is done here for now; there is no
drag-to-reorder yet.

## Layout

| Path | What |
|---|---|
| `Frosty/Model/` | Pure logic, unit-tested: config format + edits, bar layout, Dock hide/restore |
| `Frosty/System/` | Live Dock prefs, app lookup/launching, the observable model |
| `Frosty/UI/` | Bar panel + auto-hide controller, SwiftUI tiles, group grid |

## Not built (yet)

Main display only · no drag-and-drop onto icons · no badges · no window previews ·
no launch at login. Minimize, Mission Control and Cmd-Tab still use Apple's hidden
Dock, which no third-party bar can take over.
