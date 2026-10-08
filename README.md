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
| `Super + drag` | A pinned window stays pinned: let go, it snaps into the stack at the edge it's nearer to (on the monitor it's dropped on), at the height it was dropped |
| `Super + Shift + drag` | Moves any window; a pinned one is unpinned when let go and tiled where it's dropped |
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
- In a stack, an app that won't be shorter than its slot (some have a minimum
  height) keeps its own height and the others share the rest; if they can't
  (under 100 px each), that window is undocked: "Not enough room in the stack".
- A window docks to the side it's nearer to, measured from the middle of the
  space between the docked windows (not the screen's middle).
- Docked windows always leave at least 30% of the screen's width free: an
  edge's stack is at most 60% of it, and less if the other edge's stack would
  leave less free. Resizing stops there, and docking a window that couldn't get
  at least 300 px says "Not enough room to dock" instead.
- Floating windows on that screen are moved (and narrowed if they're too wide)
  into the space left beside the docked windows, so none ends up under one.
  Undocking leaves them where they are.
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
  border_opacity = 1,      -- 0 (clear) to 1 (solid) when focused
  border_unfocused = 2/3,  -- unfocused, as a share of border_opacity; 0 shows the border only on focus (hover)
  border_size = 0,         -- border width in pixels; 0 for the usual width
  glow = false,            -- a glow in the focused-border colour around the focused pinned window (only while Hyprland's shadows are off)
  glow_size = 6,           -- the glow's reach in pixels
  glow_opacity = 0.4,      -- 0 (clear) to 1 (solid)
  remember = true,         -- pin apps again when they open, where they were pinned when they closed
  notify = true,           -- a short notification on Super + Alt + P: "Docked on the right" / "Undocked"
}
```

Which windows are pinned is kept in `~/.local/state/omarchy-dock/`, so they stay
pinned across Hyprland reloads; remembered apps are in `remembered` there.
