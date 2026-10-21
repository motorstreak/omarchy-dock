-- Omarchy Dock
--
-- Pins a window to the left or right screen edge: it floats there at full
-- height on every workspace, and that strip of the screen is reserved, so tiled
-- windows are laid out beside it instead of under it. Several windows on one
-- edge stack, sharing its height (and one width).
-- They follow a monitor's resolution or scale changing.
--
--   SUPER + ALT + P  pin the focused window to the screen edge it's nearer to,
--                    or unpin a pinned one (it goes back to floating or tiled,
--                    as it was)
--   SUPER + SHIFT + LEFT/RIGHT  (a pinned window focused) move it to that edge,
--                    into the stack there
--   SUPER + SHIFT + UP/DOWN  (a pinned window focused) move it up / down its stack
--   SUPER + ARROWS   (a pinned window focused) focus the next docked window that way
--   SUPER + ALT + LEFT/RIGHT  (a pinned window focused) gather every docked
--                    window on that edge, at this one's width; (a tiled window
--                    focused) its workspace's tiled windows in a column on
--                    that side, the other half left free, and back; UP/DOWN
--                    (a tiled window focused) in a row on the top / bottom
--   SUPER + MINUS/EQUAL  (a pinned window focused) narrower / wider, its whole
--                    stack (ALT: a little, CTRL: a lot); with SHIFT, shorter /
--                    taller in its stack. A tiled window with no tiled window
--                    beside it: narrower / wider against the docked stack
--
-- Each app pinned is remembered, its edge and width (a share of the screen):
-- when it next opens (its first window, on a regular workspace), it's pinned
-- there again. Unpinning it with SUPER + ALT + P forgets it. Plain terminals
-- aren't remembered (all their programs share one app id).
--
-- Any window can be pinned, sidebars from the Sidebar plugin included: pinning
-- one moves it out of its sidebar workspace first, which makes it an ordinary
-- window again as far as that plugin is concerned.
--
-- The reserved strips are drawn by Service.qml as invisible layer surfaces with
-- an exclusive zone (as the bar reserves its space), so no monitor settings are
-- touched. This file tells it which strips to draw.
--
-- Loaded into the running Hyprland by Service.qml with DOCK_DIR set to the
-- plugin folder. Options can be overridden in ~/.config/omarchy/dock.lua (a Lua
-- file returning a table like `defaults`).

if DOCK_LOADED then
  return
end
if DOCK_DIR == nil then
  error("set DOCK_DIR to the plugin folder before loading dock.lua")
end
DOCK_LOADED = true

local home = os.getenv("HOME")
local state_home = os.getenv("XDG_STATE_HOME")
if state_home == nil or state_home == "" then
  state_home = home .. "/.local/state"
end
local state_root = state_home .. "/omarchy-dock"
local quote = o.shell_quote
os.execute("mkdir -p " .. quote(state_root))

-- Reporting --------------------------------------------------------------------

local reported, reported_count = {}, 0

local function notify(message)
  hl.exec_cmd("notify-send -a Dock -- Dock " .. quote(message))
end

-- Each distinct error is reported once per load (and at most 20 in all).
local function report(context, err)
  local message = context .. ": " .. tostring(err)
  if not reported[message] and reported_count < 20 then
    reported[message] = true
    reported_count = reported_count + 1
    notify(message)
  end
end

local function guard(context, fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then
      report(context, err)
    end
  end
end

-- Config -----------------------------------------------------------------------

local defaults = {
  pin = "SUPER + ALT + P", -- false leaves it unbound
  width = 0.3, -- width of a pinned window that wasn't floating, as a share of the screen
  -- Pinned windows' border: "none" (no border; the window fills the space a
  -- tiled window's border would), a colour name from the theme's colors.toml
  -- ("cyan", "green", "foreground", ...), a colour such as "#8cbfb8", or false
  -- for the usual border.
  border = "cyan",
  border_opacity = 1, -- 0 (clear) to 1 (solid), focused
  border_unfocused = 2 / 3, -- unfocused, as a share of border_opacity (0: shown only on focus/hover)
  border_size = 0, -- width in pixels; 0 for the usual width
  -- A glow (a shadow in the theme's focused-border colour) around the focused
  -- pinned window only. Used only while Hyprland's shadows are off; otherwise
  -- pinned windows keep the usual shadow.
  glow = false,
  glow_size = 6, -- its reach in pixels
  glow_opacity = 0.4, -- 0 (clear) to 1 (solid)
  remember = true, -- apps pinned when they closed open pinned again, at the same edge and width
  notify = true, -- a short notification on SUPER + ALT + P: "Docked on the right" / "Undocked"
}

local config = {}
for k, v in pairs(defaults) do
  config[k] = v
end
do
  local problems = {}
  local path = home .. "/.config/omarchy/dock.lua"
  local chunk, load_err = loadfile(path)
  if chunk then
    local ok, overrides = pcall(chunk)
    if not ok then
      problems[#problems + 1] = tostring(overrides)
    elseif type(overrides) ~= "table" then
      problems[#problems + 1] = "the file must return a table"
    else
      for k, v in pairs(overrides) do
        if defaults[k] == nil then
          problems[#problems + 1] = "unknown option " .. tostring(k)
        elseif type(v) == type(defaults[k]) or ((k == "pin" or k == "border") and v == false) then
          config[k] = v
        else
          problems[#problems + 1] = tostring(k) .. " must be a " .. type(defaults[k])
        end
      end
    end
  elseif load_err and not load_err:find("No such file", 1, true) then
    problems[#problems + 1] = load_err
  end
  if config.border_opacity < 0 or config.border_opacity > 1 then
    problems[#problems + 1] = "border_opacity must be between 0 and 1"
    config.border_opacity = 1
  end
  if config.border_unfocused < 0 or config.border_unfocused > 1 then
    problems[#problems + 1] = "border_unfocused must be between 0 and 1"
    config.border_unfocused = defaults.border_unfocused
  end
  if config.border_size < 0 or config.border_size ~= math.floor(config.border_size) then
    problems[#problems + 1] = "border_size must be a whole number, 0 or more"
    config.border_size = defaults.border_size
  end
  if config.glow_size < 1 or config.glow_size ~= math.floor(config.glow_size) then
    problems[#problems + 1] = "glow_size must be a whole number, 1 or more"
    config.glow_size = defaults.glow_size
  end
  if config.glow_opacity < 0 or config.glow_opacity > 1 then
    problems[#problems + 1] = "glow_opacity must be between 0 and 1"
    config.glow_opacity = defaults.glow_opacity
  end
  if config.width < 0.1 or config.width > 0.8 then
    problems[#problems + 1] = "width must be between 0.1 and 0.8"
    config.width = defaults.width
  end
  if #problems > 0 then
    notify("Problems in ~/.config/omarchy/dock.lua: " .. table.concat(problems, "; "))
  end
end

-- Pinned windows ------------------------------------------------------------------

-- By address: { edge = "left"|"right", monitor = name, width, was_floating, pos, mw }.
-- mw is the monitor's width the window's width was set for: a different one
-- (another resolution or scale, also across a reload) scales the width to match.
-- pos orders a stack, top to bottom: the middle of the window's slot as a share
-- of the screen's height.
-- Kept in a file too, as a Hyprland reload runs this file afresh while the
-- windows stay pinned.
local pinned = {}
local pinned_file = state_root .. "/pinned"

do
  local f = io.open(pinned_file, "r")
  if f then
    for line in f:lines() do
      local address, edge, monitor, width, floated, pos, mw, home =
        line:match("^(%S+) (%a+) (%S+) (%d+) ([01]) ?([%d.]*) ?(%d*) ?(%S*)$")
      if address and (edge == "left" or edge == "right") then
        pinned[address] = { edge = edge, monitor = monitor, width = tonumber(width), was_floating = floated == "1",
          pos = tonumber(pos) or 0.5, mw = tonumber(mw), home = home ~= "" and home or nil }
      end
    end
    f:close()
  end
end

-- Where a floating window was, by address { x, y, w, h }, when it was pinned:
-- unpinned, it floats there again rather than staying at the edge. Kept in a
-- file too, as a Hyprland reload runs this file afresh.
local floated = {}
local floated_file = state_root .. "/floated"

do
  local f = io.open(floated_file, "r")
  if f then
    for line in f:lines() do
      local address, x, y, w, h = line:match("^(%S+) (%-?%d+) (%-?%d+) (%d+) (%d+)$")
      if address then
        floated[address] = { x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h) }
      end
    end
    f:close()
  end
end

local function save_floated()
  local f = io.open(floated_file, "w")
  if f then
    for address, g in pairs(floated) do
      f:write(string.format("%s %d %d %d %d\n", address, g.x, g.y, g.w, g.h))
    end
    f:close()
  end
end

-- Heights set with SUPER + SHIFT + MINUS/EQUAL, by address (p.set_h, layout
-- pixels): the window keeps that height in its stack, the others share the
-- rest. Without one it shares the height equally. Saved along with `pinned`.
local heights_file = state_root .. "/heights"

do
  local f = io.open(heights_file, "r")
  if f then
    for line in f:lines() do
      local address, h = line:match("^(%S+) (%d+)$")
      if address and pinned[address] then
        pinned[address].set_h = tonumber(h)
      end
    end
    f:close()
  end
end

-- By app: { edge, share, pos } of the last window of it pinned, its width as a
-- share of the monitor's (so it opens in proportion on another monitor) and its
-- place in the stack, kept while it's pinned (a logout or crash doesn't lose
-- it) and forgotten when unpinned.
local remembered = {}
local remembered_file = state_root .. "/remembered"

-- An app's name for this: its window class, without the Chromium profile of a
-- web app ("chrome-app.example.com__-Profile_1"), which can differ per launch.
--
-- Not plain terminals: every program run in one shares its class, so the next
-- terminal opened, whatever it runs, would be pinned. A terminal program with an
-- app id of its own (omarchy-launch-tui gives "org.omarchy.<name>") is its own app.
local TERMINALS = {
  ["com.mitchellh.ghostty"] = true, ["Alacritty"] = true, ["kitty"] = true, ["foot"] = true,
  ["org.wezfurlong.wezterm"] = true,
}

local function app_of(window)
  local class = window and window.class or ""
  if class == "" or TERMINALS[class] then
    return nil
  end
  return (class:gsub("^(chrome%-.+)%-Default$", "%1"):gsub("^(chrome%-.+)%-Profile_%d+$", "%1"))
end

do
  local f = io.open(remembered_file, "r")
  if f then
    for line in f:lines() do
      local edge, share, pos, app = line:match("^(%a+) ([%d.]+) ([%d.]+) (.+)$")
      if edge == nil then
        edge, share, app = line:match("^(%a+) ([%d.]+) (.+)$")
      end
      if (edge == "left" or edge == "right") and tonumber(share) and not TERMINALS[app] then
        remembered[app] = { edge = edge, share = tonumber(share), pos = tonumber(pos) }
      end
    end
    f:close()
  end
end

local function save_remembered()
  local f = io.open(remembered_file, "w")
  if f then
    for app, r in pairs(remembered) do
      f:write(string.format("%s %.4f %.4f %s\n", r.edge, r.share, r.pos or 0.5, app))
    end
    f:close()
  end
end

local function forget(window)
  local app = app_of(window)
  if app and remembered[app] then
    remembered[app] = nil
    save_remembered()
  end
end

local function save_heights()
  local f = io.open(heights_file, "w")
  if f then
    for address, p in pairs(pinned) do
      if p.set_h then
        f:write(string.format("%s %d\n", address, p.set_h))
      end
    end
    f:close()
  end
end

local function save()
  save_heights()
  local f = io.open(pinned_file, "w")
  if f then
    for address, p in pairs(pinned) do
      f:write(string.format("%s %s %s %d %d %.4f %d%s\n", address, p.edge, p.monitor, p.width, p.was_floating and 1 or 0, p.pos,
        p.mw or 0, p.home and (" " .. p.home) or ""))
    end
    f:close()
  end
  if config.remember then
    local changed = false
    -- Monitor widths in layout pixels (as logical_size, defined below).
    local widths = {}
    for _, m in ipairs(hl.get_monitors()) do
      widths[m.name] = ((m.transform or 0) % 2 == 1 and m.height or m.width) / m.scale
    end
    for address, p in pairs(pinned) do
      local app = app_of(hl.get_window("address:" .. address))
      local mw = widths[p.monitor]
      local r = app and remembered[app]
      if app and mw and mw > 0 then
        local share = math.floor(p.width / mw * 10000 + 0.5) / 10000
        if r == nil or r.edge ~= p.edge or r.share ~= share or r.pos ~= p.pos then
          remembered[app] = { edge = p.edge, share = share, pos = p.pos }
          changed = true
        end
      end
    end
    if changed then
      save_remembered()
    end
  end
end

local function selector(window)
  return "address:" .. window.address
end

-- Hyprland can crash floating, centring, moving or resizing a window while its
-- monitor is being reconfigured (unplugged, or connected but still 0x0, as when
-- monitors are switched): so those are skipped unless the window is on a monitor
-- that's connected and has a size. Other commands (borders, tags) go ahead.
local GEOMETRY = {
  [hl.dsp.window.float] = true, [hl.dsp.window.center] = true, [hl.dsp.window.move] = true,
  [hl.dsp.window.resize] = true, [hl.dsp.window.pin] = true, [hl.dsp.window.alter_zorder] = true,
}

local function usable_monitor(m)
  if m == nil or (m.width or 0) <= 0 or (m.height or 0) <= 0 then
    return false
  end
  for _, other in ipairs(hl.get_monitors()) do
    if other.name == m.name then
      return true
    end
  end
  return false
end

local function dispatch_for(window, dsp, args)
  if GEOMETRY[dsp] then
    local now = hl.get_window(selector(window))
    if now == nil or not usable_monitor(now.monitor) then
      return
    end
  end
  args.window = selector(window)
  hl.dispatch(dsp(args))
end

local function current(address)
  return hl.get_window("address:" .. address)
end

-- The windows pinned to one edge of a monitor, top to bottom: { address, p }.
local function stack(monitor, edge)
  local list = {}
  for address, p in pairs(pinned) do
    if p.monitor == monitor and p.edge == edge then
      list[#list + 1] = { address = address, p = p }
    end
  end
  table.sort(list, function(a, b)
    if a.p.pos ~= b.p.pos then
      return a.p.pos < b.p.pos
    end
    return a.address < b.address
  end)
  return list
end

-- A stack whose windows change shares its height equally again.
local function reshare(monitor, edge)
  for _, e in ipairs(stack(monitor, edge)) do
    e.p.set_h = nil
  end
end

-- Borders ------------------------------------------------------------------------

local no_border = config.border == "none"

-- Pinned windows' border colours (focused, unfocused), or nil to leave them be.
local pinned_border = nil
if config.border and not no_border then
  local hex = config.border:match("^#(%x%x%x%x%x%x)$")
  if hex == nil then
    local f = io.open(state_home .. "/omarchy/current/theme/colors.toml", "r")
    if f then
      local colours = "\n" .. f:read("a")
      f:close()
      local pattern = '%s*=%s*"#?(%x%x%x%x%x%x)"'
      -- Some themes give only the terminal palette (color0-color15): the
      -- standard ANSI slot stands in for a missing colour name.
      local palette = {
        red = "color1", green = "color2", yellow = "color3", blue = "color4", magenta = "color5", cyan = "color6",
        bright_red = "color9", bright_green = "color10", bright_yellow = "color11",
        bright_blue = "color12", bright_magenta = "color13", bright_cyan = "color14",
      }
      local name = config.border:gsub("%p", "%%%0")
      hex = colours:match("\n%s*" .. name .. pattern)
        or (palette[config.border] and colours:match("\n%s*" .. palette[config.border] .. pattern))
    end
    if hex == nil then
      notify("No colour \"" .. config.border .. "\" in the theme; pinned windows keep the usual border")
    end
  end
  if hex then
    local function alpha(share)
      return string.format("%02x", math.floor(config.border_opacity * share * 255 + 0.5))
    end
    pinned_border = { "rgba(" .. hex .. alpha(1) .. ")", "rgba(" .. hex .. alpha(config.border_unfocused) .. ")" }
  end
end

-- The theme's border colour for normal windows, as a set_prop value (the first
-- colour of a gradient: set_prop takes one).
local function theme_border(option)
  local g = hl.get_config(option)
  local c = g and g.colors and g.colors[1]
  if type(c) == "number" then
    c = string.format("0x%08X", c)
  end
  local alpha, rgb = tostring(c):match("^0[xX](%x%x)(%x%x%x%x%x%x)$")
  return alpha and ("rgba(" .. rgb .. alpha .. ")") or nil
end

local function set_border(window, active, inactive)
  if active then
    dispatch_for(window, hl.dsp.window.set_prop, { prop = "active_border_color", value = active })
  end
  if inactive then
    dispatch_for(window, hl.dsp.window.set_prop, { prop = "inactive_border_color", value = inactive })
  end
end

-- The glow. Hyprland can only turn a window's shadow off, not on, and shadow
-- colours are global. So with shadows off, they're turned on with the glow's
-- colours (none unfocused), off again for every window by a rule, and back on
-- for pinned windows by a property, which wins over rules. A reload undoes the
-- config and rule; loading does them again.
-- The Sidebar plugin's `shadow` turns shadows on the same way when it loads
-- first (SIDEBAR_SHADOW): the glow's look wins, sidebars sharing it.
-- With the Window Style plugin, shadows (and how pinned windows look) are its.
local glowing = false
if type(window_style) == "table" and window_style.look then
  -- nothing
elseif config.glow and (not hl.get_config("decoration:shadow:enabled") or SIDEBAR_SHADOW) then
  local active = theme_border("general:col.active_border")
  local rgb = active and active:match("^rgba%((%x%x%x%x%x%x)")
  if rgb then
    hl.config({ decoration = { shadow = {
      enabled = true,
      range = config.glow_size,
      render_power = 3,
      offset = { 0, 0 },
      color = "rgba(" .. rgb .. string.format("%02x", math.floor(config.glow_opacity * 255 + 0.5)) .. ")",
      color_inactive = "rgba(" .. rgb .. "00)",
    } } })
    hl.window_rule({ name = "omarchy-dock-no-shadow", match = { class = ".*" }, no_shadow = true })
    glowing = true
  end
end

-- A border colour can't be handed back to the theme, only set, and it survives
-- reloads. So windows given the theme's colours on unpinning are remembered and
-- get the current theme's colours again on every load (a theme change reloads).
local restored_file = state_root .. "/restored-borders"

local function style(window)
  -- The Window Style plugin's look for pinned windows, if it's installed.
  local look = type(window_style) == "table" and window_style.look and window_style.look("pinned")
  if look then
    local function set(prop, v)
      dispatch_for(window, hl.dsp.window.set_prop, { prop = prop, value = v })
    end
    -- Explicitly off without one: pinned windows float, and floating windows
    -- may have one by rule.
    set("no_shadow", look.shadow and "0" or "1")
    set("border_size", look.border_size and tostring(look.border_size) or "unset")
    if look.rounding then
      set("rounding", tostring(look.rounding))
    end
    if look.active or look.inactive then
      set_border(window, look.active, look.inactive or look.active)
    end
    return
  end
  if no_border then
    dispatch_for(window, hl.dsp.window.set_prop, { prop = "border_size", value = "0" })
  else
    -- border_size, or the usual width (a window pinned with border = "none"
    -- had none).
    dispatch_for(window, hl.dsp.window.set_prop,
      { prop = "border_size", value = config.border_size > 0 and tostring(config.border_size) or "unset" })
    if pinned_border then
      set_border(window, pinned_border[1], pinned_border[2])
    end
  end
  if glowing then
    dispatch_for(window, hl.dsp.window.set_prop, { prop = "no_shadow", value = "0" })
  end
end

local function unstyle(window)
  -- Unlike a colour, a size can be handed back to the config.
  dispatch_for(window, hl.dsp.window.set_prop, { prop = "border_size", value = "unset" })
  dispatch_for(window, hl.dsp.window.set_prop, { prop = "rounding", value = "unset" })
  dispatch_for(window, hl.dsp.window.set_prop, { prop = "no_shadow", value = "unset" })
  -- The theme's colours, also after border = "none" (a window pinned with a
  -- coloured border keeps that colour, unseen, until now).
  set_border(window, theme_border("general:col.active_border"), theme_border("general:col.inactive_border"))
  local f = io.open(restored_file, "a")
  if f then
    f:write(window.address, "\n")
    f:close()
  end
end

-- Geometry -------------------------------------------------------------------------

local function gaps()
  local g = hl.get_config("general:gaps_out")
  if type(g) == "number" then
    return g, g, g, g
  end
  if g then
    return g.top or 0, g.right or 0, g.bottom or 0, g.left or 0
  end
  return 0, 0, 0, 0
end

-- The space between two tiled windows (each keeps gaps_in from the other).
local function inner_gap()
  local g = hl.get_config("general:gaps_in")
  if type(g) == "table" then
    g = g.top
  end
  return 2 * (type(g) == "number" and g or 0)
end

-- A pinned window's border width: none with border = "none".
local function border()
  if no_border then
    return 0
  end
  if config.border_size > 0 then
    return config.border_size
  end
  local b = hl.get_config("general:border_size")
  return type(b) == "number" and b or 0
end

-- The monitor's size in layout pixels (rotated by 90 or 270 degrees: swapped).
local function logical_size(m)
  local w, h = m.width / m.scale, m.height / m.scale
  if (m.transform or 0) % 2 == 1 then
    w, h = h, w
  end
  return w, h
end

local function monitor_named(name)
  for _, m in ipairs(hl.get_monitors()) do
    if m.name == name then
      return m
    end
  end
end

-- The dock's own strip at this edge of the monitor, as Hyprland has it now
-- (nil before the shell has drawn one): a layer surface { x, y, w, h }.
local function strip_layer(m, edge)
  local mw = logical_size(m)
  for _, l in ipairs(hl.get_layers()) do
    if l.namespace == "omarchy-dock-strip" and l.mapped and l.monitor and l.monitor.name == m.name
        and ((l.x + l.w / 2 < m.x + mw / 2) == (edge == "left")) then
      return l
    end
  end
end

-- The space others (a bar on that side) reserve at the left and right of the
-- monitor: the reserved space without the dock's own strips.
local function outer_sides(m)
  local r = m.reserved or {}
  local function without(edge, reserved)
    local l = strip_layer(m, edge)
    return math.max(0, (reserved or 0) - (l and l.w or 0))
  end
  return without("left", r.left), without("right", r.right)
end

-- Puts a pinned window in its strip, spaced like a tiled window: its border the
-- outer gap away from the screen edges and the bar, and windows stacked on one
-- edge the gap between tiled windows apart, sharing the height equally. (Hyprland's
-- position and size are the window's own, inside the border.)
-- A window in a stack needs at least this much height, besides what apps that
-- won't be shorter keep.
local MIN_SLOT = 100

-- A stack's slots, from the top: { y = offset, h = outer height } each. They
-- share the height equally, except that a window whose app won't be shorter
-- (p.min_h, learnt once placed) keeps its height and the others share the
-- rest. Also whether they fit.
local function slots(list, avail, gap)
  local n = #list
  local fixed, free, rest = {}, avail - (n - 1) * gap, n
  -- Heights set with the keys first, kept to what leaves the others MIN_SLOT.
  for k, e in ipairs(list) do
    if e.p.set_h and (rest > 1 or n == 1) then
      local h = math.max(math.min(e.p.set_h, free - (rest - 1) * MIN_SLOT), MIN_SLOT, e.p.min_h or 0)
      fixed[k] = h
      free, rest = free - h, rest - 1
    end
  end
  local changed = true
  while changed and rest > 0 do
    changed = false
    for k, e in ipairs(list) do
      if not fixed[k] and e.p.min_h and e.p.min_h > free / rest then
        fixed[k] = e.p.min_h
        free, rest, changed = free - e.p.min_h, rest - 1, true
      end
    end
  end
  local share = rest > 0 and math.floor(free / rest) or 0
  local last = nil
  for k = 1, n do
    if not fixed[k] then
      last = k
    end
  end
  local out, y = {}, 0
  for k = 1, n do
    -- The last shared one takes what rounding left over.
    local h = fixed[k] or (k == last and free - share * (rest - 1)) or share
    out[k] = { y = y, h = h }
    y = y + h + gap
  end
  return out, free >= (rest > 0 and rest * MIN_SLOT or 0)
end

-- The height a stack has below the bar on its monitor.
local function stack_height(m)
  local _, mh = logical_size(m)
  local top, _, bottom = gaps()
  local r = m.reserved or {}
  return mh - (r.top or 0) - (r.bottom or 0) - top - bottom
end

local function place(window, p)
  local m = monitor_named(p.monitor)
  if m == nil then
    return
  end
  local mw = logical_size(m)
  local top, right, _, left = gaps()
  local b = border()
  local r = m.reserved or {}
  local list = stack(p.monitor, p.edge)
  local i = 1
  for k, e in ipairs(list) do
    if e.address == window.address then
      i = k
    end
  end
  local s = slots(list, stack_height(m), inner_gap())[i] or { y = 0, h = stack_height(m) }
  local y = m.y + (r.top or 0) + top + s.y + b
  local height = s.h - 2 * b
  p.placed_h = math.floor(height)
  local outer_left, outer_right = outer_sides(m)
  local x = p.edge == "left" and (m.x + outer_left + left + b) or (m.x + mw - outer_right - right - b - p.width)
  p.placed_x, p.placed_y = math.floor(x), math.floor(y)
  dispatch_for(window, hl.dsp.window.resize, { x = math.floor(p.width), y = math.floor(height) })
  dispatch_for(window, hl.dsp.window.move, { x = math.floor(x), y = math.floor(y) })
  dispatch_for(window, hl.dsp.window.alter_zorder, { mode = "bottom" })
end

-- Pinned windows stay under other floating windows (a window popped out with
-- SUPER + O is pinned too, and placing, pinning or focusing one of these raises
-- it). Still above tiled windows, being floating.
local function lower_all()
  for address in pairs(pinned) do
    local window = current(address)
    if window and window.pinned then
      dispatch_for(window, hl.dsp.window.alter_zorder, { mode = "bottom" })
    end
  end
end

-- Scrolling workspaces -----------------------------------------------------------------

-- Omarchy's scrolling layout makes each column a share of the space (0.49), so
-- columns never fill it exactly, and when a strip changes the space Hyprland
-- lines the row up again: the leftover can land beside the pinned windows, so
-- the gap there grows. So once a strip has changed, the columns on screen of a
-- scrolling workspace are fitted to the space ("fit visible"), as tiled windows
-- in the other layout fill it. That acts on the focused column: focus goes to
-- one of them and straight back, with the pointer left where it is.
local function fit_scrolling(name)
  local m = monitor_named(name)
  local ws = m and m.active_workspace
  if ws == nil or ws.tiled_layout ~= "scrolling" or m.active_special_workspace or ws.has_fullscreen then
    return
  end
  local mw = logical_size(m)
  local column = nil
  for _, w in ipairs(hl.get_windows()) do
    if not w.floating and w.workspace and w.workspace.name == ws.name
        and w.at.x + w.size.x > m.x and w.at.x < m.x + mw then
      column = w
      break
    end
  end
  if column == nil then
    return
  end
  local before = hl.get_active_window()
  local no_warps = hl.get_config("cursor:no_warps")
  hl.config({ cursor = { no_warps = true } })
  if before == nil or before.address ~= column.address then
    hl.dispatch(hl.dsp.focus({ window = selector(column) }))
  end
  hl.dispatch(hl.dsp.layout("fit visible"))
  if before and before.address ~= column.address then
    hl.dispatch(hl.dsp.focus({ window = selector(before) }))
  end
  hl.config({ cursor = { no_warps = no_warps == true } })
end

-- Floating windows don't follow reserved space as tiled ones do, so a dock
-- covered them. Each floating window on the monitor (on any of its regular
-- workspaces) is moved inside the space beside the strips, at the outer gap,
-- and narrowed if it's wider than that space. (Undocking leaves them be.)
local function fit_floating(name)
  local m = monitor_named(name)
  if m == nil then
    return
  end
  local mw = logical_size(m)
  local _, right, _, left = gaps()
  local r = m.reserved or {}
  local from = m.x + (r.left or 0) + left
  local to = m.x + mw - (r.right or 0) - right
  for _, w in ipairs(hl.get_windows()) do
    local ws = w.workspace and w.workspace.name or "special:"
    if w.floating and not w.pinned and pinned[w.address] == nil and w.monitor and w.monitor.name == name
        and ws:sub(1, 8) ~= "special:" and (w.fullscreen or 0) == 0 then
      local width = math.min(w.size.x, to - from)
      local x = math.min(math.max(w.at.x, from), to - width)
      if width < w.size.x then
        -- (Resizing a floating window keeps its centre: moved after.)
        dispatch_for(w, hl.dsp.window.resize, { x = math.floor(width), y = math.floor(w.size.y) })
      end
      if width < w.size.x or x ~= w.at.x then
        dispatch_for(w, hl.dsp.window.move, { x = math.floor(x), y = math.floor(w.at.y) })
      end
    end
  end
end

local function reserved_sides(m)
  local r = m.reserved or {}
  return (r.left or 0) .. " " .. (r.right or 0)
end

-- After the strips were sent: once a monitor's reserved space has changed (the
-- shell takes a few tens of milliseconds; checked every 2 ms, for up to 200 ms)
-- and the tiled windows have been laid out in it, its scrolling columns fitted.
local fit_watch = nil
local apply_gathers

local function fit_when_strips_land()
  if fit_watch then
    return
  end
  local before = {}
  for _, m in ipairs(hl.get_monitors()) do
    before[m.name] = reserved_sides(m)
  end
  fit_watch = { before = before, tries = 0 }
  local function check()
    local watch = fit_watch
    watch.tries = watch.tries + 1
    local changed = {}
    for _, m in ipairs(hl.get_monitors()) do
      if watch.before[m.name] ~= reserved_sides(m) then
        changed[#changed + 1] = m.name
      end
    end
    if #changed > 0 or watch.tries > 100 then
      fit_watch = nil
      hl.timer(guard("fitting scrolling columns", function()
        for _, name in ipairs(changed) do
          fit_scrolling(name)
          fit_floating(name)
        end
        -- Gathered workspaces: their free half follows the docked strips.
        if #changed > 0 then
          apply_gathers()
        end
      end), { timeout = 20, type = "oneshot" })
    else
      hl.timer(guard("fitting scrolling columns", check), { timeout = 2, type = "oneshot" })
    end
  end
  hl.timer(guard("fitting scrolling columns", check), { timeout = 2, type = "oneshot" })
end

-- Strips -----------------------------------------------------------------------------

-- Service.qml draws a strip for each pinned window, ending at its border on
-- the inner side: tiled windows then keep the outer gap from it, the same as
-- the gap between two tiled windows with Omarchy's gaps. Every message carries the
-- whole list, a sequence number and an id for this load (messages are separate
-- processes and can arrive out of order; a reload numbers them afresh).
math.randomseed(os.time() + math.floor(os.clock() * 1000000))
local session = string.format("%d-%d", os.time(), math.random(1, 1000000000))
local seq = 0

-- The width a pinned window's strip reserves.
local function strip_size(p)
  local _, right, _, left = gaps()
  return math.floor(p.width + 2 * border() + (p.edge == "left" and left or right))
end

-- The docks at both edges of a monitor together take at most this share of
-- its width (strips included), leaving the rest to the workspace (or tiled
-- windows shrink to slivers); a docked window is at least MIN_WIDTH wide.
local MAX_DOCKED = 0.7
local MIN_WIDTH = 300

-- The widest a stack at this edge of the monitor may be beside the other
-- edge's stack as it is. (A window moving edges counts at its new edge only.)
local function max_width(monitor, edge)
  local m = monitor_named(monitor)
  if m == nil then
    return MIN_WIDTH
  end
  local outer_left, outer_right = outer_sides(m)
  local mw = logical_size(m) - outer_left - outer_right
  local other = stack(monitor, edge == "left" and "right" or "left")
  local taken = #other > 0 and strip_size(other[1].p) or 0
  local overhead = strip_size({ width = 0, edge = edge })
  return math.floor(mw * MAX_DOCKED - taken - overhead)
end

local function sync()
  -- One strip per stack.
  local sizes, strips = {}, {}
  for _, p in pairs(pinned) do
    local key = p.monitor .. " " .. p.edge
    local size = strip_size(p)
    if sizes[key] == nil or size > sizes[key].size then
      sizes[key] = { monitor = p.monitor, edge = p.edge, size = size }
    end
  end
  for _, st in pairs(sizes) do
    strips[#strips + 1] = string.format('{"monitor":"%s","edge":"%s","size":%d}',
      st.monitor:gsub('[%c"\\]', ""), st.edge, st.size)
  end
  fit_when_strips_land()
  seq = seq + 1
  hl.exec_cmd("omarchy-shell -q omarchy-dock set " .. quote(string.format('{"session":"%s","seq":%d,"strips":[%s]}',
    session, seq, table.concat(strips, ","))))
end

-- Places a pinned window once its strip's new size has reached Hyprland (the
-- shell takes a few tens of milliseconds), so the window and the tiled windows
-- beside it start moving in the same frame instead of one after the other.
-- Checks every 2 ms; after about 200 ms (something else reserving space on that
-- edge, say) it places the window anyway.
local place_with_strip, place_stack

-- Defined below (Pinning): a window its stack has no room for is undocked.
local overflowed

-- An app can refuse to be narrower or shorter than its own minimum: the window
-- then keeps a larger size than asked (Hyprland centres it on the smaller one),
-- hangs off the screen or over its neighbours in the stack. So, once the app
-- has answered a placement, a wider window's width becomes its pinned width,
-- and a taller one's height its minimum in the stack (see slots), and the stack
-- is placed again. (They only grow, so this settles at once.) A stack that
-- can't hold that height lets the window go.
local function adopt_width(address)
  hl.timer(guard("checking the pinned window's size", function()
    local now, p = current(address), pinned[address]
    if now == nil or p == nil or now.size == nil then
      return
    end
    local wider = now.size.x > p.width + 1
    local taller = p.placed_h and now.size.y > p.placed_h + 1
    -- Seen narrower than a minimum learnt before: that wasn't one.
    if p.min_w and now.size.x < p.min_w - 1 then
      p.min_w = nil
    end
    -- Wider or taller than asked: asked once more before believing it. Just
    -- after a window floats, Hyprland can put back its old floating size over
    -- ours, which isn't its app refusing (and a wrong minimum stuck: the stack
    -- couldn't be made narrower).
    if (wider or taller) and not p.asked_again then
      p.asked_again = true
      place(now, p)
      adopt_width(address)
      return
    end
    p.asked_again = nil
    if wider then
      -- Its app's minimum, which pushing the stack (see resize) respects.
      p.min_w = math.floor(now.size.x)
      -- The whole stack: it shares one width.
      for _, e in ipairs(stack(p.monitor, p.edge)) do
        e.p.width = p.min_w
      end
      -- The other edge's stack gives way if both now take over the limit.
      local other = stack(p.monitor, p.edge == "left" and "right" or "left")
      if #other > 0 then
        local most = math.max(max_width(p.monitor, other[1].p.edge), MIN_WIDTH)
        if other[1].p.width > most then
          for _, e in ipairs(other) do
            e.p.width = most
          end
          place_stack(p.monitor, other[1].p.edge)
        end
      end
    end
    if taller then
      p.min_h = math.floor(now.size.y) + 2 * border()
      local m = monitor_named(p.monitor)
      local _, fits = slots(stack(p.monitor, p.edge), m and stack_height(m) or 0, inner_gap())
      if not fits then
        p.min_h = nil
        -- Away from its monitor (see monitors_changed) it's crowded for a
        -- while, not undocked.
        if p.home == nil then
          overflowed(now)
        end
        return
      end
    end
    if wider or taller then
      save()
      sync()
      place_stack(p.monitor, p.edge)
    end
  end), { timeout = 150, type = "oneshot" })
end

place_with_strip = function(window)
  local address = window.address
  local tries = 0
  local function check()
    local now, p = current(address), pinned[address]
    if now == nil or p == nil then
      return
    end
    local m = monitor_named(p.monitor)
    local l = m and strip_layer(m, p.edge)
    tries = tries + 1
    if (l and math.abs(l.w - strip_size(p)) < 1) or tries > 100 then
      place(now, p)
      adopt_width(address)
    else
      hl.timer(guard("placing the pinned window", check), { timeout = 2, type = "oneshot" })
    end
  end
  check()
end

-- Every window of a stack placed again (one joined, left, or moved in it). Their
-- pos becomes the middle of their slots, so it stays a place on screen.
place_stack = function(monitor, edge)
  local list = stack(monitor, edge)
  for k, e in ipairs(list) do
    e.p.pos = math.floor((k - 0.5) / #list * 10000 + 0.5) / 10000
  end
  save()
  for _, e in ipairs(list) do
    local window = current(e.address)
    if window then
      place_with_strip(window)
    end
  end
end

-- Pinning ----------------------------------------------------------------------------

local function unpin(window)
  local p = pinned[window.address]
  if p == nil then
    return
  end
  pinned[window.address] = nil
  reshare(p.monitor, p.edge)
  save()
  sync()
  place_stack(p.monitor, p.edge)
  if window.pinned then
    dispatch_for(window, hl.dsp.window.pin, {})
  end
  if not p.was_floating and window.floating then
    dispatch_for(window, hl.dsp.window.float, { action = "toggle" })
  end
  unstyle(window)
  -- Floating before: back where it was, once unpinning has settled.
  local g = floated[window.address]
  if g then
    floated[window.address] = nil
    save_floated()
  end
  if p.was_floating then
    local address = window.address
    hl.timer(guard("placing the unpinned window", function()
      local now = current(address)
      if now == nil or pinned[address] or not now.floating then
        return
      end
      -- Its old place on the monitor it's on now, or the middle of it.
      local m = now.monitor
      local mw, mh = 0, 0
      if m then
        mw, mh = logical_size(m)
      end
      if g and m and g.x >= m.x and g.y >= m.y and g.x + g.w <= m.x + mw and g.y + g.h <= m.y + mh then
        dispatch_for(now, hl.dsp.window.resize, { x = g.w, y = g.h })
        dispatch_for(now, hl.dsp.window.move, { x = g.x, y = g.y })
      else
        dispatch_for(now, hl.dsp.window.center, {})
      end
    end), { timeout = 50, type = "oneshot" })
  end
end

-- The screen edge a window is nearer to, the width it would be pinned at (its
-- own if it floats, else a share of the screen) and its height on screen (its
-- middle as a share of the screen's height), which places it in a stack.
local function measure(window)
  local m = window.monitor
  local mw, mh = logical_size(m)
  -- Nearer the left or right of the space between the docked windows (the
  -- screen's middle is off to one side when the stacks differ in width).
  local r = m.reserved or {}
  local middle = m.x + ((r.left or 0) + mw - (r.right or 0)) / 2
  local edge = (window.at.x + window.size.x / 2) < middle and "left" or "right"
  local width = window.floating and window.size.x or mw * config.width
  local pos = (window.at.y + window.size.y / 2 - m.y) / mh
  return edge, math.floor(math.min(math.max(width, MIN_WIDTH), mw * MAX_DOCKED)), pos
end

-- Pins a window on a regular workspace to the given edge at the given width and
-- height in the stack there, or as measured where it is. In a stack, it takes
-- the stack's width.
local function pin_here(window, edge, width, pos)
  local m = window.monitor
  if m == nil then
    return
  end
  local measured_edge, measured_width, measured_pos = measure(window)
  edge, width, pos = edge or measured_edge, width or measured_width, pos or measured_pos
  local others = stack(m.name, edge)
  if #others > 0 then
    width = others[1].p.width
  else
    -- No room left beside the other edge's stack: not docked.
    local most = max_width(m.name, edge)
    if most < MIN_WIDTH then
      return false
    end
    width = math.min(width, most)
  end

  local p = { edge = edge, monitor = m.name, width = width, was_floating = window.floating == true, pos = pos,
    mw = math.floor(logical_size(m)) }
  reshare(m.name, edge)
  pinned[window.address] = p
  save()
  if window.floating then
    floated[window.address] = { x = math.floor(window.at.x), y = math.floor(window.at.y),
      w = math.floor(window.size.x), h = math.floor(window.size.y) }
    save_floated()
  end

  if not window.floating then
    dispatch_for(window, hl.dsp.window.float, { action = "toggle" })
  end
  if not window.pinned then
    dispatch_for(window, hl.dsp.window.pin, {})
  end
  -- A window popped out with SUPER + O is the dock's now: drop Omarchy's "pop"
  -- tag, or its pop-out look (rounded corners) outlives the pin.
  dispatch_for(window, hl.dsp.window.tag, { tag = "-pop" })
  style(window)
  -- Placed once floating has settled, or Hyprland restores the window's old
  -- floating geometry over ours.
  local address, monitor = window.address, m.name
  hl.timer(guard("placing the pinned window", function()
    if pinned[address] then
      place_stack(monitor, pinned[address].edge)
    end
  end), { timeout = 50, type = "oneshot" })
  sync()
  return true
end

-- Defined further down: pinning and unpinning re-check who has the swap keys.
local sync_keys_soon

-- SUPER + ALT + P says what it did: a docked window that was already floating
-- doesn't move, and its border colour can be close to the focused one.
local function announce(text)
  if config.notify then
    hl.exec_cmd("omarchy-notification-send --app-name Dock -g 󰐃 -t 1500 " .. quote(text))
  end
end

local function announce_pinned(address)
  local p = pinned[address]
  if p then
    local n = #stack(p.monitor, p.edge)
    announce("Docked on the " .. p.edge .. (n > 1 and (" (" .. n .. " stacked)") or ""))
  end
end

-- A pinned window tiled by something else (SUPER + T, say): Hyprland unpins it
-- as it tiles it, without a Lua event, so Service.qml passes on the event
-- socket's changefloatingmode. Undocked, as with SUPER + ALT + P; left pinned,
-- its strip stayed and squeezed it to a sliver. (The dock tiles a window only
-- after forgetting it.)
local function tiled(address)
  local window = current(address)
  if window == nil or pinned[address] == nil or window.floating then
    return
  end
  forget(window)
  unpin(window)
  sync_keys_soon()
end

overflowed = function(window)
  forget(window)
  unpin(window)
  sync_keys_soon()
  announce("Not enough room in the stack")
end

-- SUPER + ALT + P on the focused window.
local function toggle()
  local window = hl.get_active_window()
  if window == nil then
    return
  end
  if pinned[window.address] then
    forget(window)
    unpin(window)
    sync_keys_soon()
    announce("Undocked")
    return
  end
  local ws = window.workspace and window.workspace.name or ""
  if ws:sub(1, 8) == "special:" then
    -- A sidebar or the scratchpad: to the workspace on screen first. Hyprland
    -- won't move a pinned window (SUPER + O pins), and the Sidebar plugin lets
    -- go of a window as it leaves (tiling it again, if it was tiled before), so
    -- pinning waits for that, at the edge and width it has now.
    local regular = window.monitor and window.monitor.active_workspace
    if regular == nil then
      return
    end
    local edge, width, pos = measure(window)
    if window.pinned then
      dispatch_for(window, hl.dsp.window.pin, {})
    end
    local target = tonumber(regular.name) and regular.name or ("name:" .. regular.name)
    dispatch_for(window, hl.dsp.window.move, { workspace = target })
    local address = window.address
    hl.timer(guard("pinning the window", function()
      local now = current(address)
      if now and now.workspace and now.workspace.name:sub(1, 8) ~= "special:" then
        if not pin_here(now, edge, width, pos) then
          announce("Not enough room to dock")
          return
        end
        sync_keys_soon()
        hl.dispatch(hl.dsp.focus({ window = selector(now) }))
        announce_pinned(now.address)
      end
    end), { timeout = 150, type = "oneshot" })
    return
  end
  if not pin_here(window) then
    announce("Not enough room to dock")
    return
  end
  sync_keys_soon()
  announce_pinned(window.address)
end

-- SUPER + SHIFT + LEFT/RIGHT on a pinned window: to that edge, into the stack
-- there (at its height on screen, taking the stack's width). UP/DOWN: one place
-- up / down its stack.
local function move(direction)
  local window = hl.get_active_window()
  local p = window and pinned[window.address]
  if p == nil then
    return
  end
  if direction == "u" or direction == "d" then
    local list = stack(p.monitor, p.edge)
    for k, e in ipairs(list) do
      if e.address == window.address then
        local other = list[direction == "u" and k - 1 or k + 1]
        if other then
          p.pos, other.p.pos = other.p.pos, p.pos
          place_stack(p.monitor, p.edge)
        end
        return
      end
    end
    return
  end
  local edge = direction == "l" and "left" or "right"
  if p.edge == edge then
    return
  end
  local from = p.edge
  local others = stack(p.monitor, edge)
  reshare(p.monitor, from)
  reshare(p.monitor, edge)
  p.edge = edge
  if #others > 0 then
    p.width = others[1].p.width
  else
    local most = max_width(p.monitor, edge)
    if most < MIN_WIDTH then
      p.edge = from
      announce("Not enough room to dock")
      return
    end
    p.width = math.min(p.width, most)
  end
  -- Level with one there already (both in the middle of their slots): below it.
  p.pos = p.pos + 0.0001
  save()
  sync()
  place_stack(p.monitor, from)
  place_stack(p.monitor, edge)
end

-- SUPER + arrows on a docked window: focus the next docked window that way, up
-- or down its stack, or across to the other edge's stack (the one level with
-- it). None there: Omarchy's focus, to the windows beside it.
local function focus_dock(direction)
  local window = hl.get_active_window()
  local p = window and pinned[window.address]
  if p == nil then
    return
  end
  local target = nil
  if direction == "u" or direction == "d" then
    local list = stack(p.monitor, p.edge)
    for k, e in ipairs(list) do
      if e.address == window.address then
        target = list[direction == "u" and k - 1 or k + 1]
      end
    end
  elseif (direction == "l") == (p.edge == "right") then
    local best = nil
    for _, e in ipairs(stack(p.monitor, p.edge == "right" and "left" or "right")) do
      local d = math.abs(e.p.pos - p.pos)
      if best == nil or d < best then
        best, target = d, e
      end
    end
  end
  if target then
    hl.dispatch(hl.dsp.focus({ window = "address:" .. target.address }))
  else
    hl.dispatch(hl.dsp.focus({ direction = direction }))
  end
end

-- SUPER + ALT + LEFT/RIGHT on a docked window: every docked window on its
-- monitor gathers on that edge, in one stack at this window's width (or as
-- wide as there's room for).
local function gather(direction)
  local window = hl.get_active_window()
  local p = window and pinned[window.address]
  if p == nil then
    return
  end
  local edge = direction == "l" and "left" or "right"
  local width = p.width
  local moved = false
  reshare(p.monitor, "left")
  reshare(p.monitor, "right")
  for _, e in ipairs(stack(p.monitor, edge == "left" and "right" or "left")) do
    -- Below the ones there already.
    e.p.edge, e.p.pos = edge, e.p.pos + 1
    moved = true
  end
  for _, e in ipairs(stack(p.monitor, edge)) do
    e.p.width = width
  end
  local most = max_width(p.monitor, edge)
  if width > most then
    for _, e in ipairs(stack(p.monitor, edge)) do
      e.p.width = math.max(most, MIN_WIDTH)
    end
  end
  -- Positions back to shares of the height, in their new order.
  local list = stack(p.monitor, edge)
  for k, e in ipairs(list) do
    e.p.pos = (k - 0.5) / #list
  end
  save()
  sync()
  place_stack(p.monitor, "left")
  place_stack(p.monitor, "right")
  announce(moved and ("Gathered on the " .. edge) or ("All docked on the " .. edge))
end

-- Omarchy's swap and resize keys, which move and resize a pinned window instead
-- while one has focus. The Sidebar plugin takes the same keys while a sidebar
-- has focus and binds
-- Omarchy's back as it loses focus, so this acts just after it on each focus
-- change, and leaves the keys to it when a sidebar has focus.
-- SUPER + MINUS/EQUAL (ALT: small steps, CTRL: big ones) on a pinned window:
-- its inner edge moves left/right, as the line between two tiled windows does
-- with Omarchy's resize keys, and the tiled windows follow it.
-- Said at most every 2 seconds: a held key repeats.
local said_full = 0
local function say_full()
  if os.time() - said_full >= 2 then
    said_full = os.time()
    announce("Docks at maximum width")
  end
end

-- A stack's new width, asked by the resize keys or a mouse resize: within the
-- limits, pushing the other edge's stack if it must, and placed again.
-- (The widths only: returns the other edge, if its stack was pushed.)
local function apply_width(p, width)
  -- Not narrower than its stack's apps go (see adopt_width): the others in it
  -- stop there too.
  local own = stack(p.monitor, p.edge)
  for _, e in ipairs(own) do
    width = math.max(width, e.p.min_w or 0)
  end
  width = math.max(width, MIN_WIDTH)
  local others = stack(p.monitor, p.edge == "left" and "right" or "left")
  local pushed = false
  local most = max_width(p.monitor, p.edge)
  if width > most and #others > 0 then
    -- Past the limit, it pushes the other edge's stack, which keeps the space
    -- between them as it is, down to MIN_WIDTH (or the narrowest its apps go).
    local floor = MIN_WIDTH
    for _, e in ipairs(others) do
      floor = math.max(floor, e.p.min_w or 0)
    end
    local give = math.min(width - most, others[1].p.width - floor)
    if give > 0 then
      for _, e in ipairs(others) do
        e.p.width = math.floor(e.p.width - give)
      end
      pushed = true
      most = max_width(p.monitor, p.edge)
    end
  end
  if width > most then
    width = math.max(most, MIN_WIDTH)
    say_full()
  end
  -- The whole stack: it shares one width.
  for _, e in ipairs(stack(p.monitor, p.edge)) do
    e.p.width = math.floor(width)
  end
  return pushed and others[1].p.edge or nil
end

local function set_width(p, width)
  if monitor_named(p.monitor) == nil then
    return
  end
  local pushed = apply_width(p, width)
  save()
  sync()
  place_stack(p.monitor, p.edge)
  if pushed then
    place_stack(p.monitor, pushed)
  end
end

local function resize(dx)
  local window = hl.get_active_window()
  local p = window and pinned[window.address]
  if p then
    set_width(p, p.width + dx)
  end
end

-- SUPER + SHIFT + MINUS/EQUAL on a docked window: shorter / taller. In a stack
-- the others share what's left; alone, it stays at the top, under the bar.
-- Back to the full height (or an equal share), it shares again.
local function set_height(dy)
  local window = hl.get_active_window()
  local p = window and pinned[window.address]
  local m = p and monitor_named(p.monitor)
  if m == nil then
    return
  end
  local list = stack(p.monitor, p.edge)
  local avail = stack_height(m) - (#list - 1) * inner_gap()
  local most = avail - (#list - 1) * MIN_SLOT
  local h = (p.set_h or (p.placed_h and p.placed_h + 2 * border()) or math.floor(avail / #list)) + dy
  -- Within a border's width of all the room there is: as tall as it goes.
  if h >= most - 2 * border() - 4 then
    p.set_h = nil
    if #list > 1 then
      p.set_h = most
    end
  else
    p.set_h = math.floor(math.max(h, MIN_SLOT))
  end
  save()
  place_stack(p.monitor, p.edge)
end

-- SUPER + ALT + LEFT/RIGHT on a tiled window: the tiled windows of its
-- workspace gather in a column on that side, stacked top to bottom, half of the
-- space between the docked strips left free on the other (a wider outer gap
-- there, as a workspace rule); against a docked stack on that side, they tile
-- next to it. UP/DOWN: in a row along the top or bottom, side by side, the
-- other half free. Gathered, LEFT or RIGHT (UP or DOWN for a row) puts them
-- back across the space; the other pair gathers them the other way.
-- Remembered per workspace in a file, as a Hyprland reload drops workspace
-- rules. Only the side: the free half is worked out from the monitor the
-- workspace is on each time (a workspace gathered on a 4K monitor and shown on
-- a laptop's would otherwise keep a gap wider than the laptop's screen).
local gathered = {} -- workspace name -> { side = "left" | "right" | "top" | "bottom", applied }
local gathered_file = state_root .. "/gathered"

do
  local f = io.open(gathered_file, "r")
  if f then
    for line in f:lines() do
      -- Older files have the free share in pixels after the side: ignored.
      local ws, side = line:match("^(%S+) (%a+)")
      if ws and (side == "left" or side == "right" or side == "top" or side == "bottom") then
        gathered[ws] = { side = side }
      end
    end
    f:close()
  end
end

local function save_gathered()
  local f = io.open(gathered_file, "w")
  if f then
    for ws, g in pairs(gathered) do
      f:write(string.format("%s %s\n", ws, g.side))
    end
    f:close()
  end
end

-- Half the space between the docked strips on the workspace's monitor, across
-- (`side` left or right) or down; 0 while the workspace has no monitor (it
-- doesn't exist yet: applied again when it's shown).
local function gather_free(ws, side)
  local w = hl.get_workspace(ws)
  local m = w and w.monitor
  if m == nil or (m.width or 0) <= 0 or (m.height or 0) <= 0 then
    return 0
  end
  local r = m.reserved or {}
  local mw, mh = logical_size(m)
  local space = (side == "left" or side == "right") and (mw - (r.left or 0) - (r.right or 0))
    or (mh - (r.top or 0) - (r.bottom or 0))
  return math.max(0, math.floor(space / 2))
end

-- The workspace's outer gap: the config's, plus the free share on the side
-- away from where its windows gather.
local function apply_gather(ws)
  local top, right, bottom, left = gaps()
  local g = gathered[ws]
  local free = g and gather_free(ws, g.side) or 0
  -- Hyprland lays out only visible workspaces again: a hidden one's free half
  -- isn't in place until it's shown (see workspace.active).
  if g then
    local w = hl.get_workspace(ws)
    g.applied = w and w.visible and free or nil
  end
  if g and g.side == "left" then
    right = right + free
  elseif g and g.side == "right" then
    left = left + free
  elseif g and g.side == "top" then
    bottom = bottom + free
  elseif g then
    top = top + free
  end
  -- Omarchy keeps dwindle's splits as they are (`preserve_split`), so two
  -- windows side by side would stay so in the column: off while the space
  -- changes, each split is picked again from its new shape (a tall column
  -- stacks them, the whole width puts them side by side), then on again.
  local keep = hl.get_config("dwindle:preserve_split") == true
  if keep then
    hl.config({ dwindle = { preserve_split = false } })
  end
  hl.workspace_rule({ workspace = ws, gaps_out = { top = top, right = right, bottom = bottom, left = left } })
  if keep then
    hl.timer(guard("keeping the splits", function()
      hl.config({ dwindle = { preserve_split = true } })
    end), { timeout = 100, type = "oneshot" })
  end
end

local function tiled_gather(direction)
  local window = hl.get_active_window()
  if window == nil or window.floating or pinned[window.address] then
    return false
  end
  local m, ws = window.monitor, window.workspace and window.workspace.name
  if m == nil or ws == nil or ws:sub(1, 8) == "special:" then
    return false
  end
  local side = ({ l = "left", r = "right", u = "top", d = "bottom" })[direction]
  -- Gathered already: an arrow along the same line (LEFT or RIGHT for a column,
  -- UP or DOWN for a row) puts them back across the screen; the other two
  -- gather them the other way.
  local across = { left = "lr", right = "lr", top = "ud", bottom = "ud" }
  if gathered[ws] and across[gathered[ws].side] == across[side] then
    gathered[ws] = nil
    announce("Tiled across the screen")
  else
    gathered[ws] = { side = side }
    announce("Tiled on the " .. side)
  end
  save_gathered()
  apply_gather(ws)
  return true
end

-- Those whose free half changed (a monitor's size, scale or docked strips).
apply_gathers = function()
  for ws, g in pairs(gathered) do
    if g.applied ~= gather_free(ws, g.side) then
      apply_gather(ws)
    end
  end
end

apply_gathers()

-- SUPER + MINUS/EQUAL on a tiled window with no tiled window beside it, which
-- Hyprland can't resize (there's no split to move): the edge between it and a
-- docked stack moves instead, the right one if there's one on each side. MINUS
-- makes the tiled window narrower (the stack wider), EQUAL wider.
-- False when it isn't such a window, for Hyprland's own resize.
local function tiled_resize(dx)
  local window = hl.get_active_window()
  if window == nil or window.floating or pinned[window.address] or (window.fullscreen or 0) ~= 0 then
    return false
  end
  local m, ws = window.monitor, window.workspace and window.workspace.name
  if m == nil or ws == nil or ws:sub(1, 8) == "special:" then
    return false
  end
  for _, w in ipairs(hl.get_windows()) do
    if w.address ~= window.address and not w.floating and w.workspace and w.workspace.name == ws
        and (w.at.x + w.size.x <= window.at.x or w.at.x >= window.at.x + window.size.x) then
      return false
    end
  end
  local list = stack(m.name, "right")
  if #list == 0 then
    list = stack(m.name, "left")
  end
  if #list == 0 then
    return false
  end
  local p = list[1].p
  set_width(p, p.width - dx)
  return true
end

-- The right button let go after a mouse resize (SUPER + right mouse): a docked
-- window whose width changed gives it to its whole stack, as the keys do (an
-- app's minimum, like 1Password's, then holds for the stack); one whose height
-- changed goes back to its place in the stack.
local function resized()
  for address, p in pairs(pinned) do
    local w = current(address)
    if w and w.size and p.placed_h then
      if math.abs(w.size.x - p.width) > 2 then
        set_width(p, math.floor(w.size.x))
        return
      elseif math.abs(w.size.y - p.placed_h) > 2 or (p.placed_x and math.abs(w.at.x - p.placed_x) > 2) then
        place_stack(p.monitor, p.edge)
        return
      end
    end
  end
end

-- Dragging ---------------------------------------------------------------------------

-- The docked window under the pointer, if any.
local function pinned_at_cursor()
  local c = hl.get_cursor_pos()
  if c == nil then
    return nil
  end
  for address in pairs(pinned) do
    local w = current(address)
    if w and w.at and w.size and c.x >= w.at.x and c.x < w.at.x + w.size.x
        and c.y >= w.at.y and c.y < w.at.y + w.size.y then
      return w
    end
  end
  return nil
end

-- A docked window dragged (SUPER + left mouse) and let go stays docked: into
-- the stack at the edge it's nearer to, on the monitor it was dropped on, at
-- the height it was dropped (its place in the stack).
local function redock(window)
  local p = pinned[window.address]
  local m = window.monitor
  if p == nil then
    return
  end
  local from_monitor, from_edge = p.monitor, p.edge
  if m == nil then
    place_stack(from_monitor, from_edge)
    return
  end
  local edge, _, pos = measure(window)
  if m.name ~= from_monitor or edge ~= from_edge then
    local others = stack(m.name, edge)
    p.monitor, p.edge = m.name, edge
    if #others > 0 then
      p.width = others[1].p.width
    else
      local most = max_width(m.name, edge)
      if most < MIN_WIDTH then
        p.monitor, p.edge = from_monitor, from_edge
        announce("Not enough room to dock")
        place_stack(from_monitor, from_edge)
        return
      end
      p.width = math.min(p.width, most)
    end
    p.mw = math.floor(logical_size(m))
  end
  -- Level with one there already: below it.
  p.pos = pos + 0.0001
  save()
  sync()
  if m.name ~= from_monitor or edge ~= from_edge then
    place_stack(from_monitor, from_edge)
  end
  place_stack(p.monitor, p.edge)
end

-- SUPER + SHIFT + left mouse on a docked window: let go, it's an ordinary
-- tiled window, placed by the layout where it was dropped.
local function undock_to_tiling(window)
  local address = window.address
  forget(window)
  unpin(window)
  local now = current(address)
  if now and now.floating then
    dispatch_for(now, hl.dsp.window.float, { action = "disable" })
  end
  sync_keys_soon()
  announce("Undocked")
end

-- Set on SUPER + SHIFT + left mouse over a docked window, used on release.
local undock_drag = nil

-- The left button let go (after any drag): the window SUPER + SHIFT grabbed
-- goes to tiling; any other docked window no longer where it was placed was
-- dragged, and is docked again.
local function dropped()
  local grabbed = undock_drag
  undock_drag = nil
  if grabbed then
    local w = current(grabbed)
    if w and pinned[grabbed] then
      undock_to_tiling(w)
    end
    return
  end
  for address, p in pairs(pinned) do
    local w = current(address)
    if w and p.placed_x and w.at and (math.abs(w.at.x - p.placed_x) > 4 or math.abs(w.at.y - p.placed_y) > 4
        or (w.monitor and w.monitor.name ~= p.monitor)) then
      redock(w)
    end
  end
end

-- SUPER + right mouse on a docked window (the dock's bind while one has focus,
-- see dock_keys): its stack's inner edge follows the pointer, within the same
-- limits as the keys, until the button is let go. Hyprland reports no pointer
-- motion, so the pointer is read every frame while the button is down, and
-- only then. The windows move with it; the strip, which the shell redraws,
-- follows every 100 ms at most; saving waits for the release.
local live = nil

local function follow_pointer()
  local p = live and pinned[live.address]
  local c = hl.get_cursor_pos()
  if p == nil or c == nil or c.x == live.cx then
    return
  end
  live.cx = c.x
  local dx = c.x - live.x0
  local pushed = apply_width(p, live.w0 + (p.edge == "left" and dx or -dx))
  for _, edge in ipairs({ p.edge, pushed }) do
    for _, e in ipairs(stack(p.monitor, edge)) do
      local w = current(e.address)
      if w then
        place(w, e.p)
      end
    end
  end
end

local function start_mouse_resize()
  local w = pinned_at_cursor() or hl.get_active_window()
  local p = w and pinned[w.address]
  local c = hl.get_cursor_pos()
  if p == nil or c == nil or live then
    return
  end
  live = { address = w.address, x0 = c.x, w0 = p.width, cx = c.x, ticks = 0, synced = p.width }
  live.timer = hl.timer(guard("resizing the docked windows", function()
    if live == nil then
      return
    end
    follow_pointer()
    live.ticks = live.ticks + 1
    local now = pinned[live.address]
    if live.ticks % 6 == 0 and now and now.width ~= live.synced then
      live.synced = now.width
      sync()
    end
  end), { timeout = 16, type = "repeat" })
end

-- The button let go: saved, the strip sent, and placed with the app-minimum
-- check (see adopt_width), as after the keys. False if no such resize ran.
local function end_mouse_resize()
  if live == nil then
    return false
  end
  live.timer:set_enabled(false)
  local p = pinned[live.address]
  live = nil
  if p then
    set_width(p, p.width)
  end
  return true
end

-- Omarchy's keys a pinned window uses while it has focus: { keys, Omarchy's
-- description, Omarchy's action, ours, Omarchy's bind options }.
-- Defined below (Under sidebars, the scratchpad and fullscreen windows).
local fullscreen_dock

local dock_keys = {
  { "SUPER + SHIFT + LEFT", "Swap window to the left", hl.dsp.window.swap({ direction = "l" }), function() move("l") end },
  { "SUPER + SHIFT + RIGHT", "Swap window to the right", hl.dsp.window.swap({ direction = "r" }), function() move("r") end },
  { "SUPER + SHIFT + UP", "Swap window up", hl.dsp.window.swap({ direction = "u" }), function() move("u") end },
  { "SUPER + SHIFT + DOWN", "Swap window down", hl.dsp.window.swap({ direction = "d" }), function() move("d") end },
  { "SUPER + mouse:273", "Resize window", hl.dsp.window.resize(), function() start_mouse_resize() end, { mouse = true } },
  { "SUPER + LEFT", "Focus on left window", hl.dsp.focus({ direction = "l" }), function() focus_dock("l") end },
  { "SUPER + RIGHT", "Focus on right window", hl.dsp.focus({ direction = "r" }), function() focus_dock("r") end },
  { "SUPER + UP", "Focus on above window", hl.dsp.focus({ direction = "u" }), function() focus_dock("u") end },
  { "SUPER + DOWN", "Focus on below window", hl.dsp.focus({ direction = "d" }), function() focus_dock("d") end },
  { "SUPER + ALT + LEFT", "Move window to group on left", hl.dsp.window.move({ into_group = "l" }), function() gather("l") end,
    nil, nil, "l" },
  { "SUPER + ALT + RIGHT", "Move window to group on right", hl.dsp.window.move({ into_group = "r" }), function() gather("r") end,
    nil, nil, "r" },
  -- (A docked window has no top or bottom to gather on: Omarchy's.)
  { "SUPER + ALT + UP", "Move window to group on top", hl.dsp.window.move({ into_group = "u" }),
    function() hl.dispatch(hl.dsp.window.move({ into_group = "u" })) end, nil, nil, "u" },
  { "SUPER + ALT + DOWN", "Move window to group on bottom", hl.dsp.window.move({ into_group = "d" }),
    function() hl.dispatch(hl.dsp.window.move({ into_group = "d" })) end, nil, nil, "d" },
  { "SUPER + F", "Full screen", hl.dsp.window.fullscreen({ mode = "fullscreen" }), function() fullscreen_dock() end },
}
-- Spelled exactly as Omarchy binds them (default/hypr/bindings/tiling.lua):
-- unbinding goes by the spelling, modifier order included.
for _, step in ipairs({
  { "", "SHIFT + ", "", 100 },
  { "ALT + ", "SHIFT + ALT + ", " a little", 25 },
  { "CTRL + ", "CTRL + SHIFT + ", " a lot", 300 },
}) do
  local mods, height_mods, how, dx = step[1], step[2], step[3], step[4]
  dock_keys[#dock_keys + 1] = { "SUPER + " .. mods .. "code:20", "Expand window left" .. how,
    hl.dsp.window.resize({ x = -dx, y = 0, relative = true }), function() resize(-dx) end, nil, -dx }
  dock_keys[#dock_keys + 1] = { "SUPER + " .. mods .. "code:21", "Shrink window left" .. how,
    hl.dsp.window.resize({ x = dx, y = 0, relative = true }), function() resize(dx) end, nil, dx }
  -- With SHIFT, the height: its share of the stack, or below the bar alone.
  dock_keys[#dock_keys + 1] = { "SUPER + " .. height_mods .. "code:20", "Shrink window up" .. how,
    hl.dsp.window.resize({ x = 0, y = -dx, relative = true }), function() set_height(-dx) end }
  dock_keys[#dock_keys + 1] = { "SUPER + " .. height_mods .. "code:21", "Expand window down" .. how,
    hl.dsp.window.resize({ x = 0, y = dx, relative = true }), function() set_height(dx) end }
end
local keys_taken = false

-- The handler for one of Omarchy's width keys (SUPER + MINUS/EQUAL, with ALT or
-- CTRL) on a window that isn't docked: the docked stack's edge for a tiled
-- window alone across the screen (tiled_resize), the Sidebar plugin's for a
-- floating one (with its `floating_keys`), else Hyprland's resize. Nil for any
-- other key. The Sidebar plugin binds the keys back through this too.
local function resize_key(keys)
  for _, k in ipairs(dock_keys) do
    if k[1] == keys and k[6] then
      local dx, omarchy = k[6], k[3]
      return guard(k[2], function()
        if tiled_resize(dx) then
          return
        end
        -- A floating window: the Sidebar plugin's (with `floating_keys`).
        local theirs = sidebar and sidebar.floating_key and sidebar.floating_key(keys)
        if theirs then
          theirs()
        else
          hl.dispatch(omarchy)
        end
      end)
    end
  end
end

-- The handler for SUPER + ALT + arrows on a window that isn't docked: a
-- tiled window gathers its workspace's windows on that side (tiled_gather);
-- any other gets the Sidebar plugin's handler (with its `floating_keys`), or
-- Omarchy's move into a group. Nil for any other key. The Sidebar plugin binds
-- the keys back through this too.
local function gather_key(keys)
  for _, k in ipairs(dock_keys) do
    if k[1] == keys and k[7] then
      local direction, omarchy = k[7], k[3]
      return guard(k[2], function()
        if tiled_gather(direction) then
          return
        end
        local theirs = sidebar and sidebar.floating_key and sidebar.floating_key(keys)
        if theirs then
          theirs()
        else
          hl.dispatch(omarchy)
        end
      end)
    end
  end
end

local function sync_keys()
  local window = hl.get_active_window()
  local want = window ~= nil and pinned[window.address] ~= nil and omarchy_default_bindings ~= false
  if want == keys_taken then
    return
  end
  keys_taken = want
  -- A sidebar with focus has bound its own over these already: leave them.
  if not want and sidebar and sidebar.keys_taken and sidebar.keys_taken() then
    return
  end
  for _, k in ipairs(dock_keys) do
    hl.unbind(k[1])
    -- The Sidebar plugin's `floating_keys` also places floating windows with
    -- some of them: back to its handler, not to Omarchy.
    local theirs = not want and sidebar and sidebar.floating_key and sidebar.floating_key(k[1])
    if want then
      o.bind(k[1], k[2] .. " (pinned window)", guard("the pinned window", k[4]))
    elseif k[7] then
      o.bind(k[1], k[2], gather_key(k[1]))
    elseif theirs then
      o.bind(k[1], k[2], theirs)
    else
      o.bind(k[1], k[2], resize_key(k[1]) or k[3], k[5])
    end
  end
end

sync_keys_soon = function()
  hl.timer(guard("updating the dock keys", sync_keys), { timeout = 5, type = "oneshot" })
end

-- The width keys work for a tiled window beside a docked stack, and the
-- gather keys for tiled windows, from the start (unless a sidebar with focus
-- has its own bound).
if omarchy_default_bindings ~= false and not (sidebar and sidebar.keys_taken and sidebar.keys_taken()) then
  for _, k in ipairs(dock_keys) do
    if k[6] or k[7] then
      hl.unbind(k[1])
      o.bind(k[1], k[2], resize_key(k[1]) or gather_key(k[1]))
    end
  end
end

-- When the plugin is disabled: every pinned window back to how it was.
local function release()
  for address in pairs(pinned) do
    local window = current(address)
    if window then
      unpin(window)
    end
  end
  pinned = {}
  save()
  sync()
end

-- Screensaver ---------------------------------------------------------------------------

-- Omarchy's screensaver is a fullscreen window on each monitor, and pinned
-- windows stay on top of fullscreen ones. So while it runs they're parked on a
-- hidden workspace (unpinned: Hyprland won't move a pinned window), and come
-- back, pinned and in place, when the last screensaver window closes. Their
-- strips stay, so tiled windows don't move.
local SCREENSAVER = "org.omarchy.screensaver"
local PARKED = "special:dock-hidden"

local function screensavers()
  local n = 0
  for _, w in ipairs(hl.get_windows()) do
    if w.class == SCREENSAVER then
      n = n + 1
    end
  end
  return n
end

local function park()
  for address in pairs(pinned) do
    local window = current(address)
    if window and window.workspace and window.workspace.name ~= PARKED then
      if window.pinned then
        dispatch_for(window, hl.dsp.window.pin, {})
      end
      dispatch_for(window, hl.dsp.window.move, { workspace = PARKED, follow = false })
    end
  end
end

local after_unpark = function() end

local function unpark()
  for address, p in pairs(pinned) do
    local window = current(address)
    if window and window.workspace and window.workspace.name == PARKED then
      local m = monitor_named(p.monitor)
      local regular = m and m.active_workspace
      if regular then
        local target = tonumber(regular.name) and regular.name or ("name:" .. regular.name)
        dispatch_for(window, hl.dsp.window.move, { workspace = target, follow = false })
        local now = current(address)
        if now and not now.pinned then
          dispatch_for(now, hl.dsp.window.pin, {})
        end
        place_with_strip(now or window)
      end
    end
  end
  after_unpark()
end

-- Under sidebars, the scratchpad and fullscreen windows ------------------------------------

-- A shown special workspace (a sidebar, the scratchpad) is drawn over the
-- workspace, but pinned windows are drawn over both, and miss its dim; and they
-- stay on top of a fullscreen window too. So while one shows on a monitor, or
-- its workspace has a window in full screen (SUPER + F, not the full width of
-- SUPER + ALT + F, which leaves them room), the pinned windows there are
-- unpinned where they are (ordinary floating windows, under it), and pinned
-- again when it's gone: brought to the workspace on screen first, in case it
-- changed meanwhile, and placed again. Only windows unpinned here are pinned
-- again. A pinned window put in full screen itself is left be.
local submerged = {}

local function workspace_target(name)
  return tonumber(name) and name or ("name:" .. name)
end

local function sync_specials()
  for _, m in ipairs(hl.get_monitors()) do
    local special = m.active_special_workspace
    local ws = m.active_workspace
    local covered = (special ~= nil and special.name ~= PARKED) or (ws ~= nil and ws.fullscreen_mode == 2)
    for address, p in pairs(pinned) do
      local window = current(address)
      if p.monitor == m.name and window and window.workspace and window.workspace.name ~= PARKED
          and window.fullscreen ~= 2 then
        if covered and window.pinned then
          dispatch_for(window, hl.dsp.window.pin, {})
          submerged[address] = true
        elseif not covered and submerged[address] then
          submerged[address] = nil
          local regular = m.active_workspace
          if regular and window.workspace.name ~= regular.name then
            dispatch_for(window, hl.dsp.window.move, { workspace = workspace_target(regular.name), follow = false })
          end
          local now = current(address) or window
          if not now.pinned then
            dispatch_for(now, hl.dsp.window.pin, {})
          end
          place_with_strip(now)
        end
      end
    end
  end
end

-- Back from the screensaver under a sidebar still shown: under it again.
after_unpark = sync_specials

-- SUPER + F on a docked window: full screen, and back to its place in the
-- stack. Hyprland won't put a pinned window in full screen, so it's unpinned
-- first, as the ones under a full screen window are (above), and pinned and
-- placed again with them once it leaves full screen.
fullscreen_dock = function()
  local window = hl.get_active_window()
  if window == nil or pinned[window.address] == nil then
    hl.dispatch(hl.dsp.window.fullscreen({ mode = "fullscreen" }))
    return
  end
  if (window.fullscreen or 0) ~= 0 then
    dispatch_for(window, hl.dsp.window.fullscreen, { mode = "fullscreen" })
    return
  end
  if window.pinned then
    dispatch_for(window, hl.dsp.window.pin, {})
    submerged[window.address] = true
  end
  local address = window.address
  hl.timer(guard("putting the docked window in full screen", function()
    local now = current(address)
    if now and pinned[address] and not now.pinned then
      dispatch_for(now, hl.dsp.window.fullscreen, { mode = "fullscreen" })
    end
  end), { timeout = 20, type = "oneshot" })
end

-- Once Hyprland has finished what set it off (a window going full screen, a
-- workspace switch).
local function sync_specials_soon()
  hl.timer(guard("pinned windows under full screen windows", sync_specials), { timeout = 10, type = "oneshot" })
end

-- Loading ------------------------------------------------------------------------------

-- Defined below (Monitors).
local monitors_changed

-- Pinned windows that closed or were unpinned while this wasn't loaded.
do
  for address in pairs(pinned) do
    local window = current(address)
    local ws = window and window.workspace and window.workspace.name or ""
    -- Unpinned meanwhile: parked for the screensaver, or under a sidebar or the
    -- scratchpad (on a regular workspace; see above), which it's taken back from.
    -- Those stay floating; a tiled one was taken by something else (the Sidebar
    -- plugin, Super+T) and isn't docked any more.
    if window == nil or not window.floating
      or (not window.pinned and ws ~= PARKED and ws:sub(1, 8) == "special:") then
      pinned[address] = nil
      -- The border width and shadow back to the config's. (Not the colours:
      -- whatever took it may have set its own.)
      if window then
        dispatch_for(window, hl.dsp.window.set_prop, { prop = "border_size", value = "unset" })
        dispatch_for(window, hl.dsp.window.set_prop, { prop = "no_shadow", value = "unset" })
      end
    elseif not window.pinned and ws ~= PARKED then
      submerged[address] = true
    end
  end
  -- (Always: windows pinned before apps were remembered get remembered.)
  save()
  -- The current theme's border colours (a theme change reloads Hyprland).
  for address in pairs(pinned) do
    local window = current(address)
    if window then
      style(window)
    end
  end
  -- Placed again (a changed border or gap moves where a pinned window goes)
  -- once Hyprland has finished reloading, which otherwise puts back the
  -- geometry it had, and once the strips below have arrived.
  hl.timer(guard("placing pinned windows", function()
    -- Parked for a screensaver that has gone meanwhile: back.
    if screensavers() == 0 then
      unpark()
    end
    -- (Also scales widths for a monitor that changed meanwhile.)
    monitors_changed()
  end), { timeout = 300, type = "oneshot" })
  local f = io.open(restored_file, "r")
  local keep = {}
  if f then
    for address in f:lines() do
      local w = current(address)
      -- Not one the Sidebar plugin has given its own border since.
      local in_sidebar = w and w.workspace and w.workspace.name:match("^special:sidebar%d*$")
      if w and not pinned[address] and not in_sidebar and not keep[address] then
        keep[address] = true
        set_border(w, theme_border("general:col.active_border"), theme_border("general:col.inactive_border"))
      end
    end
    f:close()
  end
  f = io.open(restored_file, "w")
  if f then
    for address in pairs(keep) do
      f:write(address, "\n")
    end
    f:close()
  end
end
sync()
sync_specials()

-- Monitors -------------------------------------------------------------------------------

-- A monitor's resolution or scale changing, or one being plugged in or out:
-- pinned windows are placed again for the new size (their height follows it),
-- and keep their width as a share of the screen. A window whose monitor is gone
-- stays pinned, to the same edge, on the monitor Hyprland moved it to. The same
-- when the space reserved above or below changes (the bar coming back after a
-- reload, say): they fit below the bar again.

-- Each monitor's size, scale and space reserved above and below, as last placed for.
local monitor_state = {}

local function monitor_states()
  local states = {}
  for _, m in ipairs(hl.get_monitors()) do
    local r = m.reserved or {}
    local outer_left, outer_right = outer_sides(m)
    states[m.name] = string.format("%d %d %s %d %d %d %d", m.width or 0, m.height or 0, tostring(m.scale),
      r.top or 0, r.bottom or 0, outer_left, outer_right)
  end
  return states
end

-- Monitors seen gone, and since when (os.time()). One gone for a moment (all
-- of them are switched off and on as the system wakes, and come back one by
-- one) isn't followed: only one still gone after GONE_GRACE seconds.
local gone_since = {}
local GONE_GRACE = 2

-- Windows undocked because their monitor went (unplugged): by address, how
-- they were docked { edge, home, width, pos, was_floating, mw }, to dock them
-- there again when it's back. Kept in a file too, across reloads.
local away = {}
local away_file = state_root .. "/away"

do
  local f = io.open(away_file, "r")
  if f then
    for line in f:lines() do
      local address, edge, home, width, pos, floated, mw =
        line:match("^(%S+) (%a+) (%S+) (%d+) ([%d.]+) ([01]) (%d+)$")
      if address and (edge == "left" or edge == "right") and current(address) then
        away[address] = { edge = edge, home = home, width = tonumber(width), pos = tonumber(pos),
          was_floating = floated == "1", mw = tonumber(mw) }
      end
    end
    f:close()
  end
end

local function save_away()
  local f = io.open(away_file, "w")
  if f then
    for address, a in pairs(away) do
      f:write(string.format("%s %s %s %d %.4f %d %d\n", address, a.edge, a.home, a.width, a.pos,
        a.was_floating and 1 or 0, a.mw or 0))
    end
    f:close()
  end
end

-- A docked (pinned) window whose monitor was unplugged keeps pointing at it
-- (Hyprland reports monitor -1) instead of moving with its workspace, so it
-- shows nowhere, and the guard in dispatch_for skips commands for it. It's
-- unpinned and moved to the workspace on screen of `m` directly: `m` is a
-- monitor that's there, so this can't touch one being reconfigured.
local function rescue(window, m)
  local regular = m and m.active_workspace
  if regular == nil or not usable_monitor(m) then
    return
  end
  if window.pinned then
    hl.dispatch(hl.dsp.window.pin({ window = selector(window) }))
  end
  hl.dispatch(hl.dsp.window.move({ window = selector(window), workspace = workspace_target(regular.name),
    follow = false }))
end

-- The monitor a window of a vanished one goes to: its workspace's (Hyprland
-- moves the workspaces), else the focused one.
local function host_for(window, widths)
  local m = window.monitor
  if m and widths[m.name] then
    return m
  end
  local ws = window.workspace and window.workspace.monitor
  if ws and widths[ws.name] then
    return ws
  end
  local active = hl.get_active_monitor()
  if active and widths[active.name] then
    return active
  end
  for _, other in ipairs(hl.get_monitors()) do
    if widths[other.name] then
      return other
    end
  end
end

-- Docks a window that was away again on its own monitor, now that it's back:
-- moved to the workspace on screen there, then docked as it was (unless there's
-- no room for it now).
local function return_home(address, a)
  local window = current(address)
  local m = monitor_named(a.home)
  local regular = m and m.active_workspace
  if window == nil or regular == nil or pinned[address] then
    return
  end
  dispatch_for(window, hl.dsp.window.move, { workspace = workspace_target(regular.name), follow = false })
  hl.timer(guard("docking a window again", function()
    local now = current(address)
    if now == nil or pinned[address] or not now.monitor or now.monitor.name ~= a.home then
      return
    end
    local mw = logical_size(now.monitor)
    local width = (a.mw and a.mw > 0) and math.floor(a.width * mw / a.mw + 0.5) or a.width
    if pin_here(now, a.edge, width, a.pos) ~= false and pinned[address] then
      pinned[address].was_floating = a.was_floating
      save()
    end
  end), { timeout = 150, type = "oneshot" })
end

-- A pinned window back on its own monitor (see below): Hyprland won't move a
-- pinned window, so it's unpinned, moved to the workspace on that monitor and
-- pinned again. (Parked for the screensaver, it's left for unpark.)
local function go_home(window, m)
  local ws = window.workspace and window.workspace.name or ""
  local regular = m.active_workspace
  if ws == PARKED or regular == nil then
    return
  end
  if window.pinned then
    dispatch_for(window, hl.dsp.window.pin, {})
  end
  dispatch_for(window, hl.dsp.window.move, { workspace = workspace_target(regular.name), follow = false })
  local now = current(window.address)
  if now and not now.pinned then
    dispatch_for(now, hl.dsp.window.pin, {})
  end
end

monitors_changed = function()
  monitor_state = monitor_states()
  local widths = {}
  for _, m in ipairs(hl.get_monitors()) do
    if (m.width or 0) > 0 and (m.height or 0) > 0 then
      widths[m.name] = math.floor(logical_size(m))
    end
  end
  local waiting = false
  for name in pairs(gone_since) do
    if widths[name] then
      gone_since[name] = nil
    end
  end
  for _, p in pairs(pinned) do
    if widths[p.monitor] == nil and gone_since[p.monitor] == nil then
      gone_since[p.monitor] = os.time()
      waiting = true
    end
  end
  if waiting then
    -- Looked at again once the grace is over.
    hl.timer(guard("following a monitor change", function() monitors_changed() end),
      { timeout = (GONE_GRACE + 1) * 1000, type = "oneshot" })
  end
  local stacks = {}
  local leaving = {}
  for address, p in pairs(pinned) do
    local window = current(address)
    if window then
      -- Back on its own monitor, once that's back.
      if p.home and widths[p.home] then
        if p.home ~= p.monitor then
          p.monitor = p.home
          go_home(window, monitor_named(p.home))
        end
        p.home = nil
      end
      -- Its monitor gone for good (unplugged): undocked into the layout of the
      -- monitor Hyprland moved it to, and docked again when its own is back.
      -- (Docking them all on, say, a laptop panel crowded out everything else.)
      if widths[p.monitor] == nil and host_for(window, widths)
          and gone_since[p.monitor] and os.time() - gone_since[p.monitor] >= GONE_GRACE then
        away[address] = { edge = p.edge, home = p.home or p.monitor, width = p.width, pos = p.pos,
          was_floating = p.was_floating, mw = p.mw }
        table.insert(leaving, window)
      end
      local now = not away[address] and widths[p.monitor]
      if now then
        if p.mw and p.mw > 0 and p.mw ~= now then
          p.width = math.floor(p.width * now / p.mw + 0.5)
        end
        p.mw = now
        p.width = math.floor(math.min(math.max(p.width, MIN_WIDTH), now * MAX_DOCKED))
        stacks[p.monitor .. " " .. p.edge] = { p.monitor, p.edge }
      end
    end
  end
  for _, window in ipairs(leaving) do
    -- Left without a monitor, or parked behind the screensaver: onto the
    -- workspace on screen of the monitor it goes to, first.
    local ws = window.workspace and window.workspace.name or ""
    local stranded = not (window.monitor and widths[window.monitor.name])
    if stranded or ws == PARKED then
      rescue(window, host_for(window, widths))
    end
    unpin(current(window.address) or window)
  end
  -- Back: docked again on their own monitor.
  for address, a in pairs(away) do
    if current(address) == nil then
      away[address] = nil
    elseif widths[a.home] then
      away[address] = nil
      return_home(address, a)
    end
  end
  save_away()
  -- A stack shares one width (a window moved here from a monitor that's gone
  -- joins a stack that may have another).
  for _, st in pairs(stacks) do
    local list = stack(st[1], st[2])
    for _, e in ipairs(list) do
      e.p.width = list[1].p.width
    end
  end
  save()
  sync()
  -- Gathered workspaces: their free half follows their monitor's new size.
  apply_gathers()
  -- Parked for the screensaver: placed when it ends.
  if screensavers() == 0 then
    for _, st in pairs(stacks) do
      place_stack(st[1], st[2])
    end
  end
end

local monitors_pending = false

-- `check`: only if a monitor's size, scale or space above/below has changed
-- (layers open and close all the time: menus, notifications).
local function monitors_changed_soon(check)
  if monitors_pending then
    return
  end
  monitors_pending = true
  hl.timer(guard("following a monitor change", function()
    monitors_pending = false
    if check then
      local now = monitor_states()
      local same = true
      for name, state in pairs(now) do
        if monitor_state[name] ~= state then
          same = false
        end
      end
      if same then
        return
      end
    end
    monitors_changed()
  end), { timeout = 100, type = "oneshot" })
end

-- Events ---------------------------------------------------------------------------------

hl.on("monitor.layout_changed", guard("following a monitor change", function() monitors_changed_soon(false) end))
hl.on("monitor.added", guard("following a monitor change", function() monitors_changed_soon(false) end))
hl.on("monitor.removed", guard("following a monitor change", function() monitors_changed_soon(false) end))
hl.on("layer.opened", guard("following the reserved space", function() monitors_changed_soon(true) end))
hl.on("layer.closed", guard("following the reserved space", function() monitors_changed_soon(true) end))

hl.on("window.active", guard("focus change", function()
  sync_keys_soon()
  -- After the focus change has raised whatever it raises.
  hl.timer(guard("lowering pinned windows", lower_all), { timeout = 1, type = "oneshot" })
end))

hl.on("workspace.special_active", guard("pinned windows under special workspaces", sync_specials))
hl.on("window.fullscreen", guard("pinned windows under full screen windows", sync_specials_soon))
hl.on("workspace.active", guard("pinned windows under full screen windows", sync_specials_soon))

-- An app remembered opens: its first window is pinned where the app was (into
-- the stack on that edge, at its old height in it), once Hyprland has placed it,
-- if it's on a regular workspace by then (the Sidebar plugin moves its windows
-- to theirs).
local function restore(window)
  local app = app_of(window)
  local r = app and remembered[app]
  if r == nil or app:match("^sidebar%.") then
    return
  end
  for _, w in ipairs(hl.get_windows()) do
    if w.address ~= window.address and app_of(w) == app then
      return
    end
  end
  local address = window.address
  hl.timer(guard("pinning a remembered app", function()
    local now = current(address)
    local m = now and now.monitor
    local ws = now and now.workspace and now.workspace.name or "special:"
    if m == nil or pinned[address] or ws:sub(1, 8) == "special:" or screensavers() > 0 then
      return
    end
    local mw = logical_size(m)
    pin_here(now, r.edge, math.floor(math.min(math.max(r.share * mw, MIN_WIDTH), mw * MAX_DOCKED)), r.pos)
    sync_keys_soon()
  end), { timeout = 100, type = "oneshot" })
end

hl.on("window.open", guard("opening a window", function(window)
  if window and window.class == SCREENSAVER then
    park()
  elseif window and config.remember then
    restore(window)
  end
end))

hl.on("window.close", guard("closing a window", function(window)
  if window and window.class == SCREENSAVER then
    -- Closing as it fires: the last one gone when only it is left.
    if screensavers() <= 1 then
      unpark()
    end
    return
  end
  local address = window and window.address
  if address and away[address] then
    away[address] = nil
    save_away()
  end
  local p = address and pinned[address]
  if p then
    pinned[address] = nil
    save()
    sync()
    place_stack(p.monitor, p.edge)
  end
  -- A full screen window closing: the pinned windows come back.
  sync_specials_soon()
end))

-- A gathered workspace on another monitor, or shown after its monitor changed
-- while it was hidden: its free half from that monitor's size.
hl.on("workspace.move_to_monitor", guard("following a workspace", function(workspace)
  local name = workspace and workspace.name
  if name and gathered[name] then
    apply_gather(name)
  end
end))
hl.on("workspace.active", guard("following a workspace", function(workspace)
  local name = workspace and workspace.name
  local g = name and gathered[name]
  -- Only when it changed: applying again picks the splits again.
  if g and g.applied ~= gather_free(name, g.side) then
    apply_gather(name)
  end
end))

-- A pinned window can't be moved to another workspace while pinned; if it gets
-- there anyway (unpinned and moved, e.g. made a sidebar), it is no longer here.
hl.on("window.move_to_workspace", guard("moving a window", function(window, workspace)
  if window and pinned[window.address] and workspace and workspace.name:sub(1, 8) == "special:"
      and workspace.name ~= PARKED then
    -- Made a sidebar, say: no longer one to pin when it opens.
    forget(window)
    -- Its shadow back to the config's, or the glow stays with it. (Not the
    -- border: whatever took it sets its own.)
    dispatch_for(window, hl.dsp.window.set_prop, { prop = "no_shadow", value = "unset" })
    local p = pinned[window.address]
    pinned[window.address] = nil
    save()
    sync()
    place_stack(p.monitor, p.edge)
  end
  -- A full screen window moved off the workspace on screen: they come back.
  sync_specials_soon()
end))

-- Keys -----------------------------------------------------------------------------------

-- Clicking a floating window raises it (with no event to answer), so a pinned
-- window clicked would cover floating ones until the next focus change. Right
-- after each left click (once Hyprland has raised what it raises), pinned
-- windows go back under. Bound once, never unbound: the Sidebar plugin binds
-- left click too, and unbinding a key removes every binding on it. It doesn't
-- consume the click.
hl.bind("mouse:272", guard("lowering pinned windows", function()
  if next(pinned) ~= nil then
    -- 1 ms: on the next turn of Hyprland's loop, after the click's raise but
    -- before the next frame, so the raised window is never drawn.
    hl.timer(guard("lowering pinned windows", lower_all), { timeout = 1, type = "oneshot" })
  end
end), { non_consuming = true, description = "Keep pinned windows under floating ones" })

-- Dragging a docked window (SUPER + left mouse, Omarchy's move) keeps it
-- docked; SUPER + SHIFT + left mouse moves any window, and lets a docked one go
-- into tiling. Hyprland has no event for the end of a drag: the button's
-- release, with any modifiers, stands in. (Bound once: see above.)
hl.bind("SUPER + SHIFT + mouse:272", hl.dsp.window.drag(), { mouse = true, description = "Move window; undock a docked one into tiling" })
hl.bind("SUPER + SHIFT + mouse:272", guard("grabbing a docked window", function()
  local w = pinned_at_cursor()
  undock_drag = w and w.address or nil
end), { non_consuming = true })
hl.bind("mouse:272", guard("dropping a docked window", function()
  -- After Hyprland has finished the drag.
  hl.timer(guard("dropping a docked window", dropped), { timeout = 10, type = "oneshot" })
end), { release = true, non_consuming = true, ignore_mods = true })

hl.bind("mouse:273", guard("resizing a docked window", function()
  if end_mouse_resize() then
    return
  end
  -- Hyprland's own resize (a docked window that hadn't focus yet): after it.
  hl.timer(guard("resizing a docked window", resized), { timeout = 10, type = "oneshot" })
end), { release = true, non_consuming = true, ignore_mods = true })

if config.pin then
  hl.unbind(config.pin)
  o.bind(config.pin, "Pin window to the screen edge", guard("pinning the window", toggle))
end

-- For scripting and tests: `hyprctl eval 'dock.toggle()'` etc.
dock = {
  -- Every pinned window styled again (the Window Style plugin calls this when
  -- it loads, or a look changes).
  restyle = function()
    for address in pairs(pinned) do
      local window = current(address)
      if window then
        style(window)
      end
    end
  end,
  -- Every pinned window placed again (after changing gaps, say).
  refresh = function()
    for address in pairs(pinned) do
      local window = current(address)
      if window then
        place_with_strip(window)
      end
    end
  end,
  toggle = toggle,
  tiled = tiled,
  resized = resized,
  mouse_resize_start = start_mouse_resize,
  mouse_resize_stop = end_mouse_resize,
  move = move,
  resize = resize,
  set_height = set_height,
  focus = focus_dock,
  gather = gather,
  fullscreen = function()
    fullscreen_dock()
  end,
  resize_key = resize_key,
  gather_key = gather_key,
  tiled_gather = tiled_gather,
  tiled_resize = tiled_resize,
  release = release,
  sync = sync,
}
