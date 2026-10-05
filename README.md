# Omarchy Dock

Pin any window to the left or right edge of the screen. A pinned window stays
there at full height (or stacked with others pinned to that edge) on every
workspace, and that strip of the screen is kept for it: tiled windows are laid
out beside it, never under it, as if it were part of the bar.

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
| `Super + Shift + Left/Right` | With a pinned window focused: move it to that edge, into the stack there (taking its width) |
| `Super + Shift + Up/Down` | With a pinned window focused: move it up / down its stack |
| `Super + Minus / Equal` | With a pinned window focused: move its inner edge left / right, exactly as between two tiled windows; tiled windows grow or shrink to match (`Alt`: a little, `Ctrl`: a lot) |
| `Super + Shift + Minus / Equal` | With a pinned window focused: nothing. It always fills the height below the bar (or its share of a stack), so it can't grow past the screen |

- Pinned windows have the usual border in the theme's cyan, so they're easy to
  tell from other windows (and from sidebars, which use the theme's green).
  Unpinned, a window gets the theme's usual border back. (`border = "none"`
  removes it.)
- Several windows can be pinned to one edge: they stack, sharing its height
  equally with the same gap as between tiled windows, and one width (resizing
  one resizes the stack). A window joins the stack above or below the others by
  where it was on screen.
- A window that was floating keeps its width; a tiled one gets 30% of the
  screen (see `width` below). It always takes the full height below the bar
  (shared, in a stack).
- Pinned windows follow the monitor: when its resolution or scale changes, or
  the bar appears or goes, they're placed again to fit, keeping their width as a
  share of the screen. If their monitor is unplugged, they stay pinned to the
  same edge on the monitor Hyprland moves them to.
- Unpinning puts the window back the way it was: floating where it is, or tiled
  into the workspace on screen.
- Apps are remembered: close a pinned app and it's pinned again, on the same
  edge and at the same width, the next time it opens, also after logging out.
  The width and its place in the stack are kept as shares of the screen, so
  they fit another monitor or resolution in proportion. Only the app's first
  window is pinned (a second one opens as usual). Unpinning an app with
  `Super + Alt + P` forgets it.
- Plain terminals aren't remembered, since every program run in one shares its
  app id. A terminal program started with `omarchy-launch-tui <program>` (as
  Omarchy's own keys do) has its own, `org.omarchy.<program>`, and is.
- Works with sidebars from the [Sidebar](https://github.com/motorstreak/omarchy-sidebar)
  plugin: pinning one turns it into an ordinary window, pinned. To make it a
  sidebar again, unpin it and press `Super + Alt + B`.
- `Super + Shift + arrows` and `Super + [Shift/Alt/Ctrl] + Minus/Equal` are
  Omarchy's swap and resize keys; the dock takes them only while a pinned window
  has focus and hands them back after. Together with the
  Sidebar plugin (which takes them while a sidebar has focus), each gets them
  in turn.
- On a workspace in Omarchy's scrolling layout (`Super + L`), the columns on
  screen are fitted to the space whenever pinning, unpinning or resizing changes
  it, so they stay the usual gap from the pinned windows. (Scrolling columns are
  a share of the screen each and never fill it exactly, so the leftover could
  otherwise end up beside the pinned windows.) Fitting acts on the focused
  column, so focus visits one of them and comes straight back; the pointer
  doesn't move.
- A window in full screen (`Super + F`) hides the pinned windows on its
  monitor; they come back when it leaves full screen, closes, or you switch to
  another workspace. Full width (`Super + Alt + F`) leaves them be: it keeps
  their space. Sidebars and the scratchpad hide them the same way.
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
  border_opacity = 1,      -- 0 (clear) to 1 (solid) when focused; unfocused is two thirds of it
  remember = true,         -- pin apps again when they open, where they were pinned when they closed
}
```

Which windows are pinned is kept in `~/.local/state/omarchy-dock/`, so they stay
pinned across Hyprland reloads; remembered apps are in `remembered` there.
