import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

Item {
  id: root
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null
  property bool opened: false

  property string scriptPath: Quickshell.env("HOME") + "/.local/bin/clone-windows.sh"
  property string logPath: Quickshell.env("HOME") + "/.local/state/clone-windows.log"
  property string omarchyDisk: "/dev/nvme0n1"

  property var disks: [] // {name, path, size, model, type}
  property string sourcePath: ""
  property string targetPath: ""
  property bool preserveGuids: true
  property bool busy: false
  property string statusText: "Select source and target"
  property string statusColor: Color.menu.text
  property string logText: ""
  property int logSeq: 0

  function open(payloadJson) {
    try {
      var p = JSON.parse(payloadJson || "{}")
      if (p.source) root.sourcePath = p.source
      if (p.target) root.targetPath = p.target
    } catch(e) {}
    root.opened = true
    root.refreshDisks()
    Qt.callLater(function(){ keyCatcher.forceActiveFocus() })
  }
  function close() {
    root.opened = false
  }
  function toggle() {
    if (root.opened) root.close(); else root.open("{}")
  }
  function dismiss() {
    root.opened = false
    if (shell && typeof shell.hide === "function") shell.hide(manifest.id)
  }

  // ---- disk discovery ----
  Process {
    id: lsblkProc
    command: ["bash","-lc","lsblk -J -d -o NAME,SIZE,MODEL,TYPE 2>/dev/null | cat"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var txt = String(text || "").trim()
        if (!txt) return
        try {
          var j = JSON.parse(txt)
          var arr = []
          var bdevs = j.blockdevices || []
          for (var i=0;i<bdevs.length;i++) {
            var d = bdevs[i]
            if (d.type !== "disk") continue
            var path = "/dev/" + d.name
            // hide omarchy disk and zram/loop
            if (path === root.omarchyDisk) continue
            if (d.name.indexOf("zram")===0 || d.name.indexOf("loop")===0) continue
            arr.push({name: d.name, path: path, size: d.size || "", model: d.model || "", display: path + "  " + (d.size||"") + "  " + (d.model||"")})
          }
          root.disks = arr
          // auto-select if empty
          if (arr.length>=1 && !root.sourcePath) root.sourcePath = arr[0].path
          if (arr.length>=2 && !root.targetPath) root.targetPath = arr[1].path
          else if (arr.length===1 && !root.targetPath) root.targetPath = arr[0].path
        } catch(e){ root.logText += "\n[lsblk parse failed] " + e }
      }
    }
    stderr: StdioCollector { waitForEnd:true }
  }
  Process {
    id: omarchyDetectProc
    command: ["bash","-lc","findmnt -n -o SOURCE / 2>/dev/null | head -1 | xargs -I{} bash -lc 'lsblk -n -d -o PKNAME {} 2>/dev/null | head -1' | xargs -I{} bash -lc 'lsblk -n -d -o NAME /dev/{} 2>/dev/null | head -1'"]
    stdout: StdioCollector {
      waitForEnd:true
      onStreamFinished: {
        var t = String(text||"").trim()
        if (t) root.omarchyDisk = "/dev/" + t
      }
    }
  }
  function refreshDisks() {
    omarchyDetectProc.running = true
    lsblkProc.running = true
    root.statusText = "Scanning disks..."
    root.statusColor = Color.menu.text
  }

  Component.onCompleted: refreshDisks()

  // ---- clone processes ----
  Process {
    id: dryRunProc
    stdout: StdioCollector { id: dryOut; waitForEnd:true }
    stderr: StdioCollector { id: dryErr; waitForEnd:true }
    onExited: function(code) {
      root.busy = false
      var out = String(dryOut.text||"") + String(dryErr.text||"")
      // strip percent spam
      out = out.replace(/[ 0-9.]+ percent completed\r?/g,"")
      root.logText = out
      root.logSeq++
      logView.positionViewAtBeginning()
      if (out.indexOf("Data fits") !== -1) {
        root.statusText = "Dry-run: fits - ready to clone"
        root.statusColor = "#2ec27e"
      } else if (out.indexOf("does NOT fit") !== -1) {
        root.statusText = "Dry-run: DOES NOT FIT - choose larger target"
        root.statusColor = "#ff5555"
      } else if (code !== 0) {
        root.statusText = "Dry-run failed (code "+code+")"
        root.statusColor = "#ffaa00"
      } else {
        root.statusText = "Dry-run finished"
        root.statusColor = Color.menu.text
      }
    }
  }
  Process {
    id: cloneProc
    stdout: StdioCollector { id: cloneOut; waitForEnd:true }
    stderr: StdioCollector { id: cloneErr; waitForEnd:true }
    onExited: function(code) {
      root.busy = false
      var out = String(cloneOut.text||"") + String(cloneErr.text||"")
      out = out.replace(/[ 0-9.]+ percent completed\r?/g,"")
      root.logText = out
      root.logSeq++
      logView.positionViewAtBeginning()
      if (code===0) {
        root.statusText = "Clone complete - install in client PC and boot"
        root.statusColor = "#2ec27e"
      } else {
        root.statusText = "Clone failed (code "+code+") - see log"
        root.statusColor = "#ff5555"
      }
    }
  }

  function runDryRun() {
    if (!root.sourcePath || !root.targetPath) { root.statusText="Pick source and target"; root.statusColor="#ffaa00"; return }
    if (root.sourcePath === root.targetPath) { root.statusText="Source and target must differ"; root.statusColor="#ff5555"; return }
    root.busy = true
    root.statusText = "Dry-run..."
    root.statusColor = Color.menu.text
    root.logText = "Running: sudo "+Util.shellQuote(root.scriptPath)+" "+Util.shellQuote(root.sourcePath)+" "+Util.shellQuote(root.targetPath)+" --dry-run\n"
    // dry-run still needs sudo for lsblk/blkid/ntfsresize but we use pkexec so polkit shows
    dryRunProc.command = ["pkexec", root.scriptPath, root.sourcePath, root.targetPath, "--dry-run"]
    dryRunProc.running = true
  }
  function runClone() {
    if (!root.sourcePath || !root.targetPath) { root.statusText="Pick source and target"; root.statusColor="#ffaa00"; return }
    if (root.sourcePath === root.targetPath) { root.statusText="Source and target must differ"; root.statusColor="#ff5555"; return }
    if (root.sourcePath === root.omarchyDisk || root.targetPath === root.omarchyDisk) { root.statusText="Refusing Omarchy disk "+root.omarchyDisk; root.statusColor="#ff5555"; return }
    root.busy = true
    root.statusText = "Cloning - will ask confirmation YES..."
    root.statusColor = "#ffaa00"
    root.logText = "Running: sudo "+Util.shellQuote(root.scriptPath)+" "+Util.shellQuote(root.sourcePath)+" "+Util.shellQuote(root.targetPath)+(root.preserveGuids?"":" --randomize-guids")+"\nType YES at prompt in terminal if required, or use GUI confirmation.\n"
    // For GUI we pipe YES automatically
    var extra = root.preserveGuids ? [] : ["--randomize-guids"]
    var cmd = ["bash","-lc","printf 'YES\\n' | pkexec "+Util.shellQuote(root.scriptPath)+" "+Util.shellQuote(root.sourcePath)+" "+Util.shellQuote(root.targetPath)+(extra.length?" "+extra.join(" "):"")]
    // Use pkexec via bash -lc so YES pipes correctly
    cloneProc.command = cmd
    cloneProc.running = true
  }

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top:true; bottom:true; left:true; right:true }
    color: "transparent"
    WlrLayershell.namespace: "com-george-windows-clone"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: root.scrim }

    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    BorderSurface {
      id: card
      width: Math.min(Style.space(900), panel.width - Style.gapsOut*2)
      height: Math.min(Style.space(700), panel.height - Style.gapsOut*2)
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin
      MouseArea { anchors.fill: parent; onClicked: {} }

      ColumnLayout {
        id: keyCatcher
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.spacing.md
        focus: true
        Keys.onPressed: function(e){
          if (e.key===Qt.Key_Escape) { root.dismiss(); e.accepted=true }
        }

        // Header
        RowLayout {
          Layout.fillWidth: true
          Text { text: "Windows Clone"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.heading; font.bold:true }
          Item { Layout.fillWidth: true }
          Text { text: "Omarchy disk: "+root.omarchyDisk+" protected"; color: Util.alpha(root.foreground,0.6); font.family: root.fontFamily; font.pixelSize: Style.font.caption }
          Button {
            text: "Refresh"
            enabled: !root.busy
            onClicked: root.refreshDisks()
          }
          Button {
            text: "Close"
            onClicked: root.dismiss()
          }
        }

        // Pickers
        GridLayout {
          columns: 2
          columnSpacing: Style.spacing.md
          rowSpacing: Style.spacing.sm
          Layout.fillWidth: true

          Text { text: "Source"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.title }
          SearchableDropdown {
            id: sourceDrop
            Layout.fillWidth: true
            options: {
              var arr=[]; for (var i=0;i<root.disks.length;i++) arr.push({value: root.disks[i].path, label: root.disks[i].display}); return arr
            }
            value: root.sourcePath
            placeholderText: "Pick source disk"
            onChanged: function(v){ root.sourcePath = v }
          }

          Text { text: "Target WILL BE WIPED"; color: "#ff5555"; font.family: root.fontFamily; font.pixelSize: Style.font.title; font.bold:true }
          SearchableDropdown {
            id: targetDrop
            Layout.fillWidth: true
            options: {
              var arr=[]; for (var i=0;i<root.disks.length;i++) arr.push({value: root.disks[i].path, label: root.disks[i].display}); return arr
            }
            value: root.targetPath
            placeholderText: "Pick target disk"
            onChanged: function(v){ root.targetPath = v }
          }
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.xs
          Toggle {
            id: guidToggle
            Layout.fillWidth: true
            label: "Preserve GUIDs"
            description: root.preserveGuids ? "on - for client PC (keeps Disk GUIDs)" : "off - randomize for keeping both disks"
            checked: root.preserveGuids
            onClicked: root.preserveGuids = !root.preserveGuids
          }
        }

        // Actions
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.sm
          Button {
            text: root.busy ? "Working..." : "Dry-run"
            enabled: !root.busy && root.sourcePath && root.targetPath && root.sourcePath!==root.targetPath
            onClicked: root.runDryRun()
          }
          Button {
            text: root.busy ? "Cloning..." : "Clone"
            enabled: !root.busy && root.sourcePath && root.targetPath && root.sourcePath!==root.targetPath
            onClicked: root.runClone()
          }
          Item { Layout.fillWidth: true }
          Text { text: root.statusText; color: root.statusColor; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.Wrap; Layout.fillWidth:true; elide:Text.ElideRight }
        }

        // Log
        BorderSurface {
          Layout.fillWidth: true
          Layout.fillHeight: true
          radius: Style.cornerRadius
          color: Util.alpha(Color.menu.background,0.96)
          borderSpec: Border.surfaceSpec("menu","border", Util.alpha(root.border,0.35), 1)
          padding: Style.space(8)

          ListView {
            id: logView
            anchors.fill: parent
            model: ListModel { id: logModel }
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            delegate: Text {
              width: ListView.view.width
              text: model.text
              color: root.foreground
              font.family: "monospace"
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }
          }
          // repopulate on log change
          Connections {
            target: root
            function onLogSeqChanged() {
              logModel.clear()
              var lines = String(root.logText||"").split("\n")
              for (var i=0;i<lines.length;i++) logModel.append({text: lines[i]})
            }
          }
        }

        Text {
          Layout.fillWidth: true
          text: "Log: "+root.logPath+"  •  Script: "+root.scriptPath
          color: Util.alpha(root.foreground,0.55)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideMiddle
        }
      }
    }
  }
}
