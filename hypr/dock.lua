-- Omarchy Dock
--
-- Pins a window to the left or right screen edge: it floats there at full
-- height on every workspace, and that strip of the screen is reserved, so tiled
-- windows are laid out beside it instead of under it. One window per edge of
-- each monitor.
--
--   SUPER + ALT + P  pin the focused window to the screen edge it's nearer to,
--                    or unpin a pinned one (it goes back to floating or tiled,
--                    as it was)
--   SUPER + SHIFT + LEFT/RIGHT  (a pinned window focused) move it to that edge;
--                    if a window is pinned there, the two swap edges
--   SUPER + MINUS/EQUAL  (a pinned window focused) move its inner edge left /
--                    right, as between tiled windows (ALT: a little, CTRL: a lot)
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
  border = "none",
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
  if config.width < 0.1 or config.width > 0.8 then
    problems[#problems + 1] = "width must be between 0.1 and 0.8"
    config.width = defaults.width
  end
  if #problems > 0 then
    notify("Problems in ~/.config/omarchy/dock.lua: " .. table.concat(problems, "; "))
  end
end

-- Pinned windows ------------------------------------------------------------------

-- By address: { edge = "left"|"right", monitor = name, width, was_floating }.
-- Kept in a file too, as a Hyprland reload runs this file afresh while the
-- windows stay pinned.
local pinned = {}
local pinned_file = state_root .. "/pinned"

do
  local f = io.open(pinned_file, "r")
  if f then
    for line in f:lines() do
      local address, edge, monitor, width, floated = line:match("^(%S+) (%a+) (%S+) (%d+) ([01])$")
      if address and (edge == "left" or edge == "right") then
        pinned[address] = { edge = edge, monitor = monitor, width = tonumber(width), was_floating = floated == "1" }
      end
    end
    f:close()
  end
end

local function save()
  local f = io.open(pinned_file, "w")
  if f then
    for address, p in pairs(pinned) do
      f:write(string.format("%s %s %s %d %d\n", address, p.edge, p.monitor, p.width, p.was_floating and 1 or 0))
    end
    f:close()
  end
end

local function selector(window)
  return "address:" .. window.address
end

local function dispatch_for(window, dsp, args)
  args.window = selector(window)
  hl.dispatch(dsp(args))
end

local function current(address)
  return hl.get_window("address:" .. address)
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
      local name = config.border:gsub("%p", "%%%0")
      hex = ("\n" .. f:read("a")):match("\n%s*" .. name .. '%s*=%s*"#?(%x%x%x%x%x%x)"')
      f:close()
    end
    if hex == nil then
      notify("No colour \"" .. config.border .. "\" in the theme; pinned windows keep the usual border")
    end
  end
  if hex then
    pinned_border = { "rgba(" .. hex .. "ff)", "rgba(" .. hex .. "aa)" }
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
  elseif pinned_border then
    set_border(window, pinned_border[1], pinned_border[2])
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
-- outer gap away from the screen edges and the bar. (Hyprland's position and
-- size are the window's own, inside the border.)
local function place(window, p)
  local m = monitor_named(p.monitor)
  if m == nil then
    return
  end
  local mw, mh = logical_size(m)
  local top, right, bottom, left = gaps()
  local b = border()
  local r = m.reserved or {}
  local y = m.y + (r.top or 0) + top + b
  local height = mh - (r.top or 0) - (r.bottom or 0) - top - bottom - 2 * b
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
  local strips = {}
  for _, p in pairs(pinned) do
    strips[#strips + 1] = string.format('{"monitor":"%s","edge":"%s","size":%d}',
      p.monitor:gsub('[%c"\\]', ""), p.edge, strip_size(p))
  end
  seq = seq + 1
  hl.exec_cmd("omarchy-shell -q omarchy-dock set " .. quote(string.format('{"session":"%s","seq":%d,"strips":[%s]}',
    session, seq, table.concat(strips, ","))))
end

-- Places a pinned window once its strip's new size has reached Hyprland (the
-- shell takes a few tens of milliseconds), so the window and the tiled windows
-- beside it start moving in the same frame instead of one after the other.
-- Checks every 2 ms; after about 200 ms (something else reserving space on that
-- edge, say) it places the window anyway.
local function place_with_strip(window)
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
    else
      hl.timer(guard("placing the pinned window", check), { timeout = 2, type = "oneshot" })
    end
  end
  check()
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
  if window.pinned then
    dispatch_for(window, hl.dsp.window.pin, {})
  end
  if not p.was_floating and window.floating then
    dispatch_for(window, hl.dsp.window.float, { action = "toggle" })
  end
  unstyle(window)
end

-- The screen edge a window is nearer to, and the width it would be pinned at:
-- its own if it floats, else a share of the screen.
local function measure(window)
  local m = window.monitor
  local mw = logical_size(m)
  local edge = (window.at.x + window.size.x / 2) < (m.x + mw / 2) and "left" or "right"
  local width = window.floating and window.size.x or mw * config.width
  return edge, math.floor(math.min(math.max(width, 300), mw * 0.6))
end

-- Pins a window on a regular workspace to the given edge at the given width,
-- or as measured where it is.
local function pin_here(window, edge, width)
  local m = window.monitor
  if m == nil then
    return
  end
  if edge == nil then
    edge, width = measure(window)
  end

  -- One per edge: the window already there goes back to how it was.
  for address, p in pairs(pinned) do
    if p.monitor == m.name and p.edge == edge and address ~= window.address then
      local other = current(address)
      if other then
        unpin(other)
      else
        pinned[address] = nil
      end
    end
  end

  local p = { edge = edge, monitor = m.name, width = width, was_floating = window.floating == true }
  pinned[window.address] = p
  save()

  if not window.floating then
    dispatch_for(window, hl.dsp.window.float, { action = "toggle" })
  end
  if not window.pinned then
    dispatch_for(window, hl.dsp.window.pin, {})
  end
  style(window)
  -- Placed once floating has settled, or Hyprland restores the window's old
  -- floating geometry over ours.
  local address = window.address
  hl.timer(guard("placing the pinned window", function()
    local now = current(address)
    if now and pinned[address] then
      place(now, pinned[address])
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
    local edge, width = measure(window)
    if window.pinned then
      dispatch_for(window, hl.dsp.window.pin, {})
    end
    local target = tonumber(regular.name) and regular.name or ("name:" .. regular.name)
    dispatch_for(window, hl.dsp.window.move, { workspace = target })
    local address = window.address
    hl.timer(guard("pinning the window", function()
      local now = current(address)
      if now and now.workspace and now.workspace.name:sub(1, 8) ~= "special:" then
        pin_here(now, edge, width)
        sync_keys_soon()
        hl.dispatch(hl.dsp.focus({ window = selector(now) }))
      end
    end), { timeout = 150, type = "oneshot" })
    return
  end
  pin_here(window)
  sync_keys_soon()
end

-- SUPER + SHIFT + LEFT/RIGHT on a pinned window: to that edge, swapping with
-- the window pinned there, if any. Each keeps its width.
local function move(direction)
  local window = hl.get_active_window()
  local p = window and pinned[window.address]
  if p == nil then
    return
  end
  local edge = direction == "l" and "left" or "right"
  if p.edge == edge then
    return
  end
  local swapped = nil
  for address, other in pairs(pinned) do
    if other.monitor == p.monitor and other.edge == edge then
      local w = current(address)
      if w then
        other.edge = p.edge
        swapped = w
      else
        pinned[address] = nil
      end
    end
  end
  p.edge = edge
  save()
  sync()
  place_with_strip(window)
  if swapped then
    place_with_strip(swapped)
  end
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
  p.width = math.floor(math.min(math.max(width, 300), mw * 0.6))
  save()
  sync()
  place_with_strip(window)
end

-- Omarchy's keys a pinned window uses while it has focus: { keys, Omarchy's
-- description, Omarchy's action, ours }.
local dock_keys = {
  { "SUPER + SHIFT + LEFT", "Swap window to the left", hl.dsp.window.swap({ direction = "l" }), function() move("l") end },
  { "SUPER + SHIFT + RIGHT", "Swap window to the right", hl.dsp.window.swap({ direction = "r" }), function() move("r") end },
}
for _, step in ipairs({ { "", "", 100 }, { "ALT + ", " a little", 25 }, { "CTRL + ", " a lot", 300 } }) do
  local mods, how, dx = step[1], step[2], step[3]
  dock_keys[#dock_keys + 1] = { "SUPER + " .. mods .. "code:20", "Expand window left" .. how,
    hl.dsp.window.resize({ x = -dx, y = 0, relative = true }), function() resize(-dx) end }
  dock_keys[#dock_keys + 1] = { "SUPER + " .. mods .. "code:21", "Shrink window left" .. how,
    hl.dsp.window.resize({ x = dx, y = 0, relative = true }), function() resize(dx) end }
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
end

-- Loading ------------------------------------------------------------------------------

-- Pinned windows that closed or were unpinned while this wasn't loaded.
do
  local changed = false
  for address in pairs(pinned) do
    local window = current(address)
    -- (A parked one isn't pinned meanwhile; see Screensaver.)
    local parked = window and window.workspace and window.workspace.name == PARKED
    if window == nil or not (window.pinned or parked) then
      pinned[address] = nil
      changed = true
    end
  end
  if changed then
    save()
  end
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

-- Events ---------------------------------------------------------------------------------

hl.on("window.active", guard("focus change", function()
  sync_keys_soon()
  -- After the focus change has raised whatever it raises.
  hl.timer(guard("lowering pinned windows", lower_all), { timeout = 5, type = "oneshot" })
end))

hl.on("window.open", guard("hiding pinned windows", function(window)
  if window and window.class == SCREENSAVER then
    park()
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
  if address and pinned[address] then
    pinned[address] = nil
    save()
    sync()
  end
end))

-- A pinned window can't be moved to another workspace while pinned; if it gets
-- there anyway (unpinned and moved, e.g. made a sidebar), it is no longer here.
hl.on("window.move_to_workspace", guard("moving a window", function(window, workspace)
  if window and pinned[window.address] and workspace and workspace.name:sub(1, 8) == "special:"
      and workspace.name ~= PARKED then
    pinned[window.address] = nil
    save()
    sync()
  end
end))

-- Keys -----------------------------------------------------------------------------------

-- Clicking a floating window raises it (with no event to answer), so a pinned
-- window clicked would cover floating ones until the next focus change. Just
-- after each left click (once Hyprland has raised what it raises), pinned
-- windows go back under. Bound once, never unbound: the Sidebar plugin binds
-- left click too, and unbinding a key removes every binding on it. It doesn't
-- consume the click.
hl.bind("mouse:272", guard("lowering pinned windows", function()
  if next(pinned) ~= nil then
    hl.timer(guard("lowering pinned windows", lower_all), { timeout = 20, type = "oneshot" })
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
