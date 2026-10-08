import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Omarchy shell plugins can't ship Hyprland config, so this service loads
// hypr/dock.lua into the running Hyprland with `hyprctl eval`: once at start and
// again after every config reload (which discards anything loaded at runtime).
//
// It also draws the strips that keep tiled windows clear of pinned ones: an
// invisible layer surface along the edge with an exclusive zone, the way the
// bar reserves its space. dock.lua sends the list whenever it changes.
Item {
  id: root

  // Injected by omarchy-shell.
  property var shell: null

  readonly property string pluginDir: decodeURIComponent(Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")).replace(/\/$/, "")

  // A Lua long-bracket string that can hold any path.
  function luaString(value) {
    var level = ""
    while (value.indexOf("]" + level + "]") !== -1) level += "="
    return "[" + level + "[" + value + "]" + level + "]"
  }

  // Loads dock.lua unless this exact source is already loaded. Changed source
  // (a plugin update) can't be loaded over the old one, whose handlers stay
  // registered, so it reloads Hyprland, which brings it back here fresh.
  function load() {
    if (loader.running) {
      loader.pending = true
      return
    }
    loader.command = ["hyprctl", "eval",
      "DOCK_DIR = " + luaString(root.pluginDir) + "; " +
      "local f = io.open(DOCK_DIR .. '/hypr/dock.lua'); " +
      "local source = f and f:read('a'); if f then f:close() end; " +
      "if DOCK_LOADED and DOCK_SOURCE ~= source then DOCK_SOURCE = source; hl.exec_cmd('hyprctl reload'); return end; " +
      "DOCK_SOURCE = source; " +
      "if DOCK_LOADED then dock.sync(); return end; " +
      "local ok, err = pcall(dofile, DOCK_DIR .. '/hypr/dock.lua'); " +
      "if not ok then error(err, 0) end"]
    loader.running = true
  }

  // hyprctl eval's output without Hyprland's warnings (a dispatch that didn't
  // apply, say), which don't stop dock.lua loading: logged, not reported.
  function problems(text) {
    return text.trim().split("\n").filter(function(line) {
      if (line.indexOf("warning:") !== 0) return line !== "" && line !== "ok"
      console.warn("dock: " + line)
      return false
    }).join("\n")
  }

  function report(message) {
    console.warn("dock: loading into Hyprland failed: " + message)
    Quickshell.execDetached(["notify-send", "-a", "Dock", "--", "Dock failed to load", message])
  }

  property int connectRetries: 0
  Timer {
    id: retry
    interval: 1000
    onTriggered: root.load()
  }

  Process {
    id: loader
    property bool pending: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = root.problems(text)
        if (result === "") {
          root.connectRetries = 0
        } else if (result.indexOf("Couldn't connect") === 0 && root.connectRetries < 5) {
          root.connectRetries += 1
          retry.restart()
        } else {
          root.report(result)
        }
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = root.problems(text)
        if (result !== "") root.report(result)
      }
    }
    onExited: function() {
      if (pending) {
        pending = false
        root.load()
      }
    }
  }

  // Hyprland's events, on a connection of the dock's own. The shell's (the
  // Hyprland module's) is made once and never again if Hyprland closes it
  // (quickshell #989); after that a reload left the dock unloaded until the
  // shell restarted. This one is made afresh until it connects again. It loads
  // on connecting, in case a reload came while it was down or before it first
  // connected (a plugin update reloads Hyprland while this service is new).
  function eventsUp() {
    reconnect.stop()
    load()
  }

  function eventsDown() {
    reconnect.restart()
  }

  function handleEvent(line) {
    var split = line.indexOf(">>")
    var name = split < 0 ? line : line.slice(0, split)
    if (name === "configreloaded") load()
    // A window tiled (SUPER + T): dock.lua undocks it if it was pinned.
    else if (name === "changefloatingmode") {
      var m = line.slice(split + 2).match(/^([0-9a-f]+),0$/)
      if (m) Quickshell.execDetached(["hyprctl", "eval", "if dock and dock.tiled then dock.tiled('0x" + m[1] + "') end"])
    }
    // Hyprland doesn't move other windows while one is fullscreen, so a pinned
    // window placed meanwhile (after a reload, say) is placed again.
    else if (name === "fullscreen" && line.slice(split + 2) === "0")
      Quickshell.execDetached(["hyprctl", "eval", "if dock and dock.refresh then dock.refresh() end"])
  }

  LazyLoader {
    id: events
    active: true

    Socket {
      path: Quickshell.env("XDG_RUNTIME_DIR") + "/hypr/" + Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") + "/.socket2.sock"
      connected: true
      onConnectionStateChanged: connected ? root.eventsUp() : root.eventsDown()
      // A socket that connects at once does so before the handler above is
      // attached, and one that fails never changes state: so check.
      Component.onCompleted: Qt.callLater(function() { connected ? root.eventsUp() : root.eventsDown() })
      parser: SplitParser {
        onRead: function(line) { root.handleEvent(line) }
      }
    }
  }

  // A fresh socket each try: setting `connected` again after a failed try
  // doesn't try again.
  Timer {
    id: reconnect
    interval: 2000
    onTriggered: {
      events.active = false
      events.active = true
    }
  }

  // Started after Hyprland (a shell restart): load, or have the loaded dock.lua
  // send its strips again.
  Component.onCompleted: load()

  // Strips ---------------------------------------------------------------------

  // [{ monitor, edge, size }]
  property var strips: []
  // The strips by "<monitor> <edge>": a strip stays the same surface while only
  // its size changes. (New objects each message would make new surfaces, and
  // for a moment both the old and the new strip reserved space, so tiled windows
  // jumped on every resize step.)
  readonly property var stripKeys: strips.map(function(s) { return s.monitor + " " + s.edge })
  readonly property var stripSizes: {
    var sizes = {}
    for (var i = 0; i < strips.length; i++) sizes[strips[i].monitor + " " + strips[i].edge] = strips[i].size
    return sizes
  }
  property string session: ""
  property int seq: -1

  function sessionTime(id) {
    return Number(String(id).split("-")[0]) || 0
  }

  // Messages are separate processes and can arrive out of order; each load of
  // dock.lua numbers them afresh under a new "<load time>-<random>" id.
  function newer(messageSession, messageSeq) {
    if (messageSession !== session) {
      if (sessionTime(messageSession) < sessionTime(session)) return false
      session = messageSession
      seq = messageSeq
      return true
    }
    if (messageSeq <= seq) return false
    seq = messageSeq
    return true
  }

  function screenNamed(name) {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (screens[i].name === name) return screens[i]
    }
    return null
  }

  IpcHandler {
    target: "omarchy-dock"
    function set(payload: string): string {
      var p = JSON.parse(payload)
      if (root.newer(String(p.session), p.seq)) root.strips = p.strips
      return "ok"
    }
    function state(): string { return JSON.stringify({ session: root.session, seq: root.seq, strips: root.strips }) }
  }

  Variants {
    // Strings: an unchanged key keeps its strip.
    model: root.stripKeys

    PanelWindow {
      required property string modelData
      readonly property string monitor: modelData.split(" ")[0]
      readonly property string edge: modelData.split(" ")[1]
      readonly property int size: root.stripSizes[modelData] || 0

      screen: root.screenNamed(monitor)
      visible: screen !== null
      anchors {
        top: true
        bottom: true
        left: edge === "left"
        right: edge === "right"
      }
      implicitWidth: size
      exclusiveZone: size
      color: "transparent"
      WlrLayershell.namespace: "omarchy-dock-strip"
      // Hyprland lays out layers from the bottom one up, each in the space the
      // ones before left over. On the overlay layer the strip comes after the
      // bar, so the bar keeps the full width and the strip starts below it.
      // It's invisible and takes no input, so being on top is harmless.
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      mask: Region {}
    }
  }

  // The shell destroys services on every plugin rescan and restart, not only
  // when this plugin is disabled. So wait, and unload only if it really is
  // disabled or removed: unpin the windows first, then reload Hyprland to drop
  // the key and handlers.
  Component.onDestruction: Quickshell.execDetached(["bash", "-c",
    "sleep 3; " +
    "for i in $(seq 30); do out=$(omarchy plugin list --json 2>/dev/null) && [ -n \"$out\" ] && break; out=; sleep 1; done; " +
    "[ -n \"$out\" ] || exit 0; " +
    "jq -e 'type == \"array\"' >/dev/null <<<\"$out\" || exit 0; " +
    "jq -e '.[] | select(.id == \"dock\" and .enabled)' >/dev/null <<<\"$out\" && exit 0; " +
    "hyprctl eval 'if dock then dock.release() end' >/dev/null; sleep 0.5; hyprctl reload >/dev/null"])
}
