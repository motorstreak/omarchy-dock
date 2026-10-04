# Omarchy Dock

Pin any window to the left or right edge of the screen. A pinned window stays
there at full height on every workspace, and that strip of the screen is kept
for it: tiled windows are laid out beside it, never under it, as if it were part
of the bar.

## Install

```bash
omarchy plugin add https://github.com/motorstreak/omarchy-dock.git --enable
```

Update with `omarchy plugin update dock`; if an update changes `Service.qml`,
also run `omarchy restart shell`.

Remove it with `omarchy plugin remove dock`, or disable it with
`omarchy plugin disable dock`. A few seconds later, pinned windows go back to how
they were and the key goes away.

## Use

| Key | Action |
|---|---|
| `Super + Alt + P` | Pin the focused window to the screen edge it's nearer to, or unpin a pinned one |
| `Super + Shift + Left/Right` | With a pinned window focused: move it to that edge. If a window is pinned there, the two swap edges (each keeps its width) |
| `Super + Minus / Equal` | With a pinned window focused: move its inner edge left / right, exactly as between two tiled windows; tiled windows grow or shrink to match (`Alt`: a little, `Ctrl`: a lot) |
| `Super + Shift + Minus / Equal` | With a pinned window focused: nothing. It always fills the height below the bar, so it can't grow past the screen |

- Pinned windows have the usual border in the theme's cyan, so they're easy to
  tell from other windows (and from sidebars, which use the theme's green).
  Unpinned, a window gets the theme's usual border back. (`border = "none"`
  removes it.)
- One window per edge of each monitor: pinning another window on the same edge
  unpins the first.
- A window that was floating keeps its width; a tiled one gets 30% of the
  screen (see `width` below). It always takes the full height below the bar.
- Unpinning puts the window back the way it was: floating where it is, or tiled
  into the workspace on screen.
- Works with sidebars from the [Sidebar](https://github.com/motorstreak/omarchy-sidebar)
  plugin: pinning one turns it into an ordinary window, pinned. To make it a
  sidebar again, unpin it and press `Super + Alt + B`.
- `Super + Shift + Left/Right` and `Super + [Shift/Alt/Ctrl] + Minus/Equal` are
  Omarchy's swap and resize keys; the dock takes them only while a pinned window
  has focus and hands them back after. Together with the
  Sidebar plugin (which takes them while a sidebar has focus), each gets them
  in turn.
- Pinned windows are Hyprland's own pinned windows (as with `Super + O`), so
  they float above tiled ones; the reserved strip is what keeps the two apart.
  Floating and fullscreen windows can still go over it.

The strips are invisible layer surfaces drawn by the Omarchy shell, the same way
the bar reserves its space, so your monitor settings are never changed.

## Configure

Create `~/.config/omarchy/dock.lua` returning the options to change, then
reload Hyprland (`hyprctl reload`). All options, with their defaults:

```lua
return {
  pin = "SUPER + ALT + P", -- false leaves it unbound
  width = 0.3,             -- width for a tiled window being pinned, as a share of the screen (0.1-0.8)
  border = "cyan",         -- pinned windows' border: a theme colour name ("cyan", "green", ...), "#8cbfb8", "none", or false for the usual one
}
```

Which windows are pinned is kept in `~/.local/state/omarchy-dock/`, so they stay
pinned across Hyprland reloads.
