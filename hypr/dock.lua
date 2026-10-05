-- Omarchy Dock
--
-- Pins a window to the left or right screen edge: it floats there at full
-- height on every workspace, and that strip of the screen is reserved, so tiled
-- windows are laid out beside it instead of under it. Several windows on one
-- edge stack, sharing its height (and one width).
--
--   SUPER + ALT + P  pin the focused window to the screen edge it's nearer to,
--                    or unpin a pinned one (it goes back to floating or tiled,
--                    as it was)
--   SUPER + SHIFT + LEFT/RIGHT  (a pinned window focused) move it to that edge,
--                    into the stack there
--   SUPER + SHIFT + UP/DOWN  (a pinned window focused) move it up / down its stack
--   SUPER + MINUS/EQUAL  (a pinned window focused) move its inner edge left /
--                    right, as between tiled windows (ALT: a little, CTRL: a lot);
--                    with SHIFT (height) it keeps its height
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
  border_opacity = 1, -- 0 (clear) to 1 (solid), focused; unfocused is two thirds of it
  remember = true, -- apps pinned when they closed open pinned again, at the same edge and width
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
  if config.width < 0.1 or config.width > 0.8 then
    problems[#problems + 1] = "width must be between 0.1 and 0.8"
    config.width = defaults.width
  end
  if #problems > 0 then
    notify("Problems in ~/.config/omarchy/dock.lua: " .. table.concat(problems, "; "))
  end
end

-- Pinned windows ------------------------------------------------------------------

-- By address: { edge = "left"|"right", monitor = name, width, was_floating, pos }.
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
      local address, edge, monitor, width, floated, pos = line:match("^(%S+) (%a+) (%S+) (%d+) ([01]) ?([%d.]*)$")
      if address and (edge == "left" or edge == "right") then
        pinned[address] = { edge = edge, monitor = monitor, width = tonumber(width), was_floating = floated == "1",
          pos = tonumber(pos) or 0.5 }
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

local function save()
  local f = io.open(pinned_file, "w")
  if f then
    for address, p in pairs(pinned) do
      f:write(string.format("%s %s %s %d %d %.4f\n", address, p.edge, p.monitor, p.width, p.was_floating and 1 or 0, p.pos))
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
    pinned_border = { "rgba(" .. hex .. alpha(1) .. ")", "rgba(" .. hex .. alpha(2 / 3) .. ")" }
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

-- A border colour can't be handed back to the theme, only set, and it survives
-- reloads. So windows given the theme's colours on unpinning are remembered and
-- get the current theme's colours again on every load (a theme change reloads).
local restored_file = state_root .. "/restored-borders"

local function style(window)
  if no_border then
    dispatch_for(window, hl.dsp.window.set_prop, { prop = "border_size", value = "0" })
  else
    -- The usual width (a window pinned with border = "none" had none).
    dispatch_for(window, hl.dsp.window.set_prop, { prop = "border_size", value = "unset" })
    if pinned_border then
      set_border(window, pinned_border[1], pinned_border[2])
    end
  end
end

local function unstyle(window)
  -- Unlike a colour, a size can be handed back to the config.
  dispatch_for(window, hl.dsp.window.set_prop, { prop = "border_size", value = "unset" })
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

-- Puts a pinned window in its strip, spaced like a tiled window: its border the
-- outer gap away from the screen edges and the bar, and windows stacked on one
-- edge the gap between tiled windows apart, sharing the height equally. (Hyprland's
-- position and size are the window's own, inside the border.)
local function place(window, p)
  local m = monitor_named(p.monitor)
  if m == nil then
    return
  end
  local mw, mh = logical_size(m)
  local top, right, bottom, left = gaps()
  local b = border()
  local r = m.reserved or {}
  local list = stack(p.monitor, p.edge)
  local n, i = math.max(#list, 1), 1
  for k, e in ipairs(list) do
    if e.address == window.address then
      i = k
    end
  end
  local gap = inner_gap()
  local avail = mh - (r.top or 0) - (r.bottom or 0) - top - bottom
  local slot = math.floor((avail - (n - 1) * gap) / n)
  local y = m.y + (r.top or 0) + top + (i - 1) * (slot + gap) + b
  -- The last one takes what rounding left over.
  local height = (i == n and (avail - (n - 1) * (slot + gap)) or slot) - 2 * b
  local x = p.edge == "left" and (m.x + left + b) or (m.x + mw - right - b - p.width)
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

local function reserved_sides(m)
  local r = m.reserved or {}
  return (r.left or 0) .. " " .. (r.right or 0)
end

-- After the strips were sent: once a monitor's reserved space has changed (the
-- shell takes a few tens of milliseconds; checked every 2 ms, for up to 200 ms)
-- and the tiled windows have been laid out in it, its scrolling columns fitted.
local fit_watch = nil

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

-- An app can refuse to be narrower than its own minimum: the window then
-- keeps a larger width than asked, placed for the smaller one, and hangs off
-- the screen. So, once the app has answered a placement, a wider window's
-- width becomes its pinned width and it's placed again. (It only grows, so
-- this settles at once.)
local function adopt_width(address)
  hl.timer(guard("checking the pinned window's width", function()
    local now, p = current(address), pinned[address]
    if now and p and now.size and now.size.x > p.width + 1 then
      -- The whole stack: it shares one width.
      for _, e in ipairs(stack(p.monitor, p.edge)) do
        e.p.width = math.floor(now.size.x)
      end
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
    local r = m and m.reserved or {}
    local reserved = p.edge == "left" and r.left or r.right
    tries = tries + 1
    if (reserved and math.abs(reserved - strip_size(p)) < 1) or tries > 100 then
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
end

-- The screen edge a window is nearer to, the width it would be pinned at (its
-- own if it floats, else a share of the screen) and its height on screen (its
-- middle as a share of the screen's height), which places it in a stack.
local function measure(window)
  local m = window.monitor
  local mw, mh = logical_size(m)
  local edge = (window.at.x + window.size.x / 2) < (m.x + mw / 2) and "left" or "right"
  local width = window.floating and window.size.x or mw * config.width
  local pos = (window.at.y + window.size.y / 2 - m.y) / mh
  return edge, math.floor(math.min(math.max(width, 300), mw * 0.6)), pos
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
  end

  local p = { edge = edge, monitor = m.name, width = width, was_floating = window.floating == true, pos = pos }
  pinned[window.address] = p
  save()

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
end

-- Defined further down: pinning and unpinning re-check who has the swap keys.
local sync_keys_soon

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
        pin_here(now, edge, width, pos)
        sync_keys_soon()
        hl.dispatch(hl.dsp.focus({ window = selector(now) }))
      end
    end), { timeout = 150, type = "oneshot" })
    return
  end
  pin_here(window)
  sync_keys_soon()
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
  if #others > 0 then
    p.width = others[1].p.width
  end
  p.edge = edge
  -- Level with one there already (both in the middle of their slots): below it.
  p.pos = p.pos + 0.0001
  save()
  sync()
  place_stack(p.monitor, from)
  place_stack(p.monitor, edge)
end

-- Omarchy's swap and resize keys, which move and resize a pinned window instead
-- while one has focus. The Sidebar plugin takes the same keys while a sidebar
-- has focus and binds
-- Omarchy's back as it loses focus, so this acts just after it on each focus
-- change, and leaves the keys to it when a sidebar has focus.
-- SUPER + MINUS/EQUAL (ALT: small steps, CTRL: big ones) on a pinned window:
-- its inner edge moves left/right, as the line between two tiled windows does
-- with Omarchy's resize keys, and the tiled windows follow it.
local function resize(dx)
  local window = hl.get_active_window()
  local p = window and pinned[window.address]
  if p == nil then
    return
  end
  local m = monitor_named(p.monitor)
  if m == nil then
    return
  end
  local mw = logical_size(m)
  local width = p.edge == "right" and (p.width - dx) or (p.width + dx)
  width = math.floor(math.min(math.max(width, 300), mw * 0.6))
  -- The whole stack: it shares one width.
  for _, e in ipairs(stack(p.monitor, p.edge)) do
    e.p.width = width
  end
  save()
  sync()
  place_stack(p.monitor, p.edge)
end

-- A pinned window's height keys: it keeps its height (its share of the stack), in place.
local function keep_height()
  local window = hl.get_active_window()
  local p = window and pinned[window.address]
  if p then
    place(window, p)
  end
end

-- Omarchy's keys a pinned window uses while it has focus: { keys, Omarchy's
-- description, Omarchy's action, ours }.
local dock_keys = {
  { "SUPER + SHIFT + LEFT", "Swap window to the left", hl.dsp.window.swap({ direction = "l" }), function() move("l") end },
  { "SUPER + SHIFT + RIGHT", "Swap window to the right", hl.dsp.window.swap({ direction = "r" }), function() move("r") end },
  { "SUPER + SHIFT + UP", "Swap window up", hl.dsp.window.swap({ direction = "u" }), function() move("u") end },
  { "SUPER + SHIFT + DOWN", "Swap window down", hl.dsp.window.swap({ direction = "d" }), function() move("d") end },
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
    hl.dsp.window.resize({ x = -dx, y = 0, relative = true }), function() resize(-dx) end }
  dock_keys[#dock_keys + 1] = { "SUPER + " .. mods .. "code:21", "Shrink window left" .. how,
    hl.dsp.window.resize({ x = dx, y = 0, relative = true }), function() resize(dx) end }
  -- With SHIFT, Omarchy's keys change the height: a pinned window always fills
  -- the height below the bar (as its strip does), so they keep it there rather
  -- than let it grow past the screen.
  dock_keys[#dock_keys + 1] = { "SUPER + " .. height_mods .. "code:20", "Shrink window up" .. how,
    hl.dsp.window.resize({ x = 0, y = -dx, relative = true }), function() keep_height() end }
  dock_keys[#dock_keys + 1] = { "SUPER + " .. height_mods .. "code:21", "Expand window down" .. how,
    hl.dsp.window.resize({ x = 0, y = dx, relative = true }), function() keep_height() end }
end
local keys_taken = false

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
    if want then
      o.bind(k[1], k[2] .. " (pinned window)", guard("the pinned window", k[4]))
    else
      o.bind(k[1], k[2], k[3])
    end
  end
end

sync_keys_soon = function()
  hl.timer(guard("updating the dock keys", sync_keys), { timeout = 5, type = "oneshot" })
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

-- Under sidebars and the scratchpad -----------------------------------------------------

-- A shown special workspace (a sidebar, the scratchpad) is drawn over the
-- workspace, but pinned windows are drawn over both, and miss its dim. So while
-- one shows on a monitor, the pinned windows there are unpinned where they are
-- (ordinary floating windows, under it and dimmed with the rest), and pinned
-- again when it's gone: brought to the workspace on screen first, in case it
-- changed meanwhile. Only windows unpinned here are pinned again.
local submerged = {}

local function workspace_target(name)
  return tonumber(name) and name or ("name:" .. name)
end

local function sync_specials()
  for _, m in ipairs(hl.get_monitors()) do
    local special = m.active_special_workspace
    local covered = special ~= nil and special.name ~= PARKED
    for address, p in pairs(pinned) do
      local window = current(address)
      if p.monitor == m.name and window and window.workspace and window.workspace.name ~= PARKED then
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
          dispatch_for(now, hl.dsp.window.alter_zorder, { mode = "bottom" })
        end
      end
    end
  end
end

-- Back from the screensaver under a sidebar still shown: under it again.
after_unpark = sync_specials

-- Loading ------------------------------------------------------------------------------

-- Pinned windows that closed or were unpinned while this wasn't loaded.
do
  for address in pairs(pinned) do
    local window = current(address)
    local ws = window and window.workspace and window.workspace.name or ""
    -- Unpinned meanwhile: parked for the screensaver, or under a sidebar or the
    -- scratchpad (on a regular workspace; see above), which it's taken back from.
    if window == nil or (not window.pinned and ws ~= PARKED and ws:sub(1, 8) == "special:") then
      pinned[address] = nil
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
    for address in pairs(pinned) do
      local window = current(address)
      if window then
        place_with_strip(window)
      end
    end
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

-- Events ---------------------------------------------------------------------------------

hl.on("window.active", guard("focus change", function()
  sync_keys_soon()
  -- After the focus change has raised whatever it raises.
  hl.timer(guard("lowering pinned windows", lower_all), { timeout = 1, type = "oneshot" })
end))

hl.on("workspace.special_active", guard("pinned windows under special workspaces", sync_specials))

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
    pin_here(now, r.edge, math.floor(math.min(math.max(r.share * mw, 300), mw * 0.6)), r.pos)
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
  local p = address and pinned[address]
  if p then
    pinned[address] = nil
    save()
    sync()
    place_stack(p.monitor, p.edge)
  end
end))

-- A pinned window can't be moved to another workspace while pinned; if it gets
-- there anyway (unpinned and moved, e.g. made a sidebar), it is no longer here.
hl.on("window.move_to_workspace", guard("moving a window", function(window, workspace)
  if window and pinned[window.address] and workspace and workspace.name:sub(1, 8) == "special:"
      and workspace.name ~= PARKED then
    -- Made a sidebar, say: no longer one to pin when it opens.
    forget(window)
    local p = pinned[window.address]
    pinned[window.address] = nil
    save()
    sync()
    place_stack(p.monitor, p.edge)
  end
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

if config.pin then
  hl.unbind(config.pin)
  o.bind(config.pin, "Pin window to the screen edge", guard("pinning the window", toggle))
end

-- For scripting and tests: `hyprctl eval 'dock.toggle()'` etc.
dock = {
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
  move = move,
  resize = resize,
  release = release,
  sync = sync,
}
