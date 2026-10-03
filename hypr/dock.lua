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
        elseif type(v) == type(defaults[k]) or (k == "pin" and v == false) then
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

local function border()
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

local function sync()
  local _, right, _, left = gaps()
  local b = border()
  local strips = {}
  for _, p in pairs(pinned) do
    strips[#strips + 1] = string.format('{"monitor":"%s","edge":"%s","size":%d}',
      p.monitor:gsub('[%c"\\]', ""), p.edge, math.floor(p.width + 2 * b + (p.edge == "left" and left or right)))
  end
  seq = seq + 1
  hl.exec_cmd("omarchy-shell -q omarchy-dock set " .. quote(string.format('{"session":"%s","seq":%d,"strips":[%s]}',
    session, seq, table.concat(strips, ","))))
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

-- SUPER + ALT + P on the focused window.
local function toggle()
  local window = hl.get_active_window()
  if window == nil then
    return
  end
  if pinned[window.address] then
    unpin(window)
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
        hl.dispatch(hl.dsp.focus({ window = selector(now) }))
      end
    end), { timeout = 150, type = "oneshot" })
    return
  end
  pin_here(window)
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

-- Loading ------------------------------------------------------------------------------

-- Pinned windows that closed or were unpinned while this wasn't loaded.
do
  local changed = false
  for address in pairs(pinned) do
    local window = current(address)
    if window == nil or not window.pinned then
      pinned[address] = nil
      changed = true
    end
  end
  if changed then
    save()
  end
end
sync()

-- Events ---------------------------------------------------------------------------------

hl.on("window.close", guard("closing a window", function(window)
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
  if window and pinned[window.address] and workspace and workspace.name:sub(1, 8) == "special:" then
    pinned[window.address] = nil
    save()
    sync()
  end
end))

-- Keys -----------------------------------------------------------------------------------

if config.pin then
  hl.unbind(config.pin)
  o.bind(config.pin, "Pin window to the screen edge", guard("pinning the window", toggle))
end

-- For scripting and tests: `hyprctl eval 'dock.toggle()'` etc.
dock = {
  toggle = toggle,
  release = release,
  sync = sync,
}
