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
  property string omarchyDisk: "" // detected via findmnt/lsblk, no hardcode

  property var disks: [] // {name, path, size, model, type}
  property string sourcePath: ""
  property string targetPath: ""
  property bool preserveGuids: true
  property bool busy: false
  property string statusText: "Select source and target"
  property string statusColor: Color.menu.text
  property string logText: ""
  property int logSeq: 0
  property bool confirmOpen: false
  property string pendingAction: "" // "dryrun" or "clone"
  property bool scriptExists: true
  property string scriptExistsMsg: ""

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
    // robust detect: handles /dev/mapper/root -> dm -> partition -> disk, and /boot fallback, like clone-windows.sh
    command: ['bash','-lc','ROOT_SRC=$(findmnt -n -o SOURCE / 2>/dev/null); OMARCHY=""; if [[ "$ROOT_SRC" == /dev/mapper/* ]]; then DM=$(basename "${ROOT_SRC%%\\[*}" ); DM_DEV=$(readlink -f "/dev/$DM" 2>/dev/null || echo "/dev/$DM"); PART=$(lsblk -n -o PKNAME "$DM_DEV" 2>/dev/null | head -1); [[ -z "$PART" ]] && PART=$(lsblk -n -o PKNAME "/dev/$DM" 2>/dev/null | head -1); if [[ -n "$PART" ]]; then PARENT=$(lsblk -n -d -o PKNAME "/dev/$PART" 2>/dev/null | head -1); if [[ -n "$PARENT" ]]; then OMARCHY="/dev/$PARENT"; else OMARCHY="/dev/$PART"; fi; if [[ $(lsblk -n -d -o TYPE "$OMARCHY" 2>/dev/null) != "disk" ]]; then P2=$(lsblk -n -d -o PKNAME "$OMARCHY" 2>/dev/null | head -1); [[ -n "$P2" ]] && OMARCHY="/dev/$P2"; fi; fi; elif [[ -n "$ROOT_SRC" && -b "${ROOT_SRC%%\\[*}" ]]; then DEV="${ROOT_SRC%%\\[*}"; P=$(lsblk -n -d -o PKNAME "$DEV" 2>/dev/null | head -1); [[ -n "$P" ]] && OMARCHY="/dev/$P" || OMARCHY="$DEV"; fi; if [[ -z "$OMARCHY" || ! -b "$OMARCHY" ]]; then BOOT_SRC=$(findmnt -n -o SOURCE /boot 2>/dev/null); if [[ -n "$BOOT_SRC" && -b "$BOOT_SRC" ]]; then P=$(lsblk -n -d -o PKNAME "$BOOT_SRC" 2>/dev/null | head -1); [[ -n "$P" ]] && OMARCHY="/dev/$P" || OMARCHY="${BOOT_SRC%p1}"; fi; fi; if [[ -n "$OMARCHY" && -b "$OMARCHY" ]]; then readlink -f "$OMARCHY" 2>/dev/null || echo "$OMARCHY"; fi']
    stdout: StdioCollector {
      waitForEnd:true
      onStreamFinished: {
        var t = String(text||"").trim()
        if (t) {
          root.omarchyDisk = t
          root.statusText = "Detected Omarchy disk: " + t + " protected"
        } else {
          root.omarchyDisk = ""
          root.statusText = "Could not detect Omarchy disk — verify target"
        }
        // now that we know omarchyDisk, scan visible disks
        lsblkProc.running = true
      }
    }
  }
  function refreshDisks() {
    root.statusText = "Scanning disks..."
    root.statusColor = Color.menu.text
    omarchyDetectProc.running = true
    // lsblk runs after detection finishes
  }

  // Check script exists at startup
  Process {
    id: scriptCheckProc
    command: ["bash","-lc","test -x \"$1\" && echo ok || echo missing; ls -l \"$1\" 2>&1 | head -1","--", Quickshell.env("HOME") + "/.local/bin/clone-windows.sh"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = String(text||"").trim()
        if (t.indexOf("ok") === -1) {
          root.scriptExists = false
          root.scriptExistsMsg = "Script not found: " + root.scriptPath + " — run: mkdir -p ~/.local/bin && cp clone-windows.sh ~/.local/bin/"
          root.statusText = root.scriptExistsMsg
          root.statusColor = root.urgent
        } else {
          root.scriptExists = true
          root.scriptExistsMsg = ""
        }
      }
    }
  }

  Component.onCompleted: { refreshDisks(); scriptCheckProc.running = true }

  function _updateLogLive(outId, errId) {
    var out = String(outId.text||"") + String(errId.text||"")
    out = out.replace(/[ 0-9.]+ percent completed\r?/g,"")
    root.logText = out
    root.logSeq++
    Qt.callLater(function(){ if (logView) logView.positionViewAtEnd() })
  }

  // ---- clone processes (stream live so UI not frozen 10-20 min) ----
  Process {
    id: dryRunProc
    stdout: StdioCollector { id: dryOut; waitForEnd:false; onTextChanged: root._updateLogLive(dryOut, dryErr) }
    stderr: StdioCollector { id: dryErr; waitForEnd:false; onTextChanged: root._updateLogLive(dryOut, dryErr) }
    onExited: function(code) {
      root._updateLogLive(dryOut, dryErr)
      var out = String(dryOut.text||"") + String(dryErr.text||"")
      out = out.replace(/[ 0-9.]+ percent completed\r?/g,"")
      root.busy = false
      if (out.indexOf("Data fits") !== -1) {
        root.statusText = "Dry-run: fits - ready to clone"
        root.statusColor = root.success
      } else if (out.indexOf("does NOT fit") !== -1) {
        root.statusText = "Dry-run: DOES NOT FIT - choose larger target"
        root.statusColor = root.urgent
      } else if (code !== 0) {
        root.statusText = "Dry-run failed (code "+code+")"
        root.statusColor = root.warning
      } else {
        root.statusText = "Dry-run finished"
        root.statusColor = Color.menu.text
      }
    }
  }
  Process {
    id: cloneProc
    stdout: StdioCollector { id: cloneOut; waitForEnd:false; onTextChanged: root._updateLogLive(cloneOut, cloneErr) }
    stderr: StdioCollector { id: cloneErr; waitForEnd:false; onTextChanged: root._updateLogLive(cloneOut, cloneErr) }
    onExited: function(code) {
      root._updateLogLive(cloneOut, cloneErr)
      var out = String(cloneOut.text||"") + String(cloneErr.text||"")
      out = out.replace(/[ 0-9.]+ percent completed\r?/g,"")
      root.busy = false
      if (code===0) {
        root.statusText = "✓ Clone complete — install in client PC and boot"
        root.statusColor = root.success
      } else {
        var m = out.match(/(ERROR:.*|Failed to add.*|sfdisk restore failed)/)
        var hint = m ? " — " + m[0].slice(0,80) : ""
        root.statusText = "✗ Clone failed (code "+code+")" + hint + " — see log tail"
        root.statusColor = root.urgent
      }
    }
  }

  function runDryRun() {
    if (!root.scriptExists) { root.statusText=root.scriptExistsMsg; root.statusColor=root.urgent; return }
    if (!root.sourcePath || !root.targetPath) { root.statusText="Pick source and target"; root.statusColor=root.warning; return }
    if (root.sourcePath === root.targetPath) { root.statusText="Source and target must differ"; root.statusColor=root.urgent; return }
    if (!root.omarchyDisk) { root.statusText="Omarchy disk not detected — cannot verify safety, refresh"; root.statusColor=root.warning; return }
    root.busy = true
    root.statusText = "Dry-run..."
    root.statusColor = Color.menu.text
    root.logText = "Running: sudo "+Util.shellQuote(root.scriptPath)+" "+Util.shellQuote(root.sourcePath)+" "+Util.shellQuote(root.targetPath)+" --dry-run\n"
    dryRunProc.command = ["pkexec", root.scriptPath, root.sourcePath, root.targetPath, "--dry-run"]
    dryRunProc.running = true
  }
  function requestClone() {
    if (!root.scriptExists) { root.statusText=root.scriptExistsMsg; root.statusColor=root.urgent; return }
    if (!root.sourcePath || !root.targetPath) { root.statusText="Pick source and target"; root.statusColor=root.warning; return }
    if (root.sourcePath === root.targetPath) { root.statusText="Source and target must differ"; root.statusColor=root.urgent; return }
    if (!root.omarchyDisk) { root.statusText="Omarchy disk not detected — refusing for safety, refresh"; root.statusColor=root.urgent; return }
    if (root.omarchyDisk && (root.sourcePath === root.omarchyDisk || root.targetPath === root.omarchyDisk)) { root.statusText="Refusing Omarchy disk "+root.omarchyDisk; root.statusColor=root.urgent; return }
    root.pendingAction = "clone"
    root.confirmOpen = true
  }
  function runClone() {
    root.confirmOpen = false
    root.busy = true
    root.statusText = "Cloning — wiping target..."
    root.statusColor = root.warning
    root.logText = "Running: sudo "+Util.shellQuote(root.scriptPath)+" "+Util.shellQuote(root.sourcePath)+" "+Util.shellQuote(root.targetPath)+(root.preserveGuids?"":" --randomize-guids")+"\n"
    var extra = root.preserveGuids ? [] : ["--randomize-guids"]
    var cmd = ["bash","-lc","printf 'YES\\n' | pkexec "+Util.shellQuote(root.scriptPath)+" "+Util.shellQuote(root.sourcePath)+" "+Util.shellQuote(root.targetPath)+(extra.length?" "+extra.join(" "):"")]
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
  property color urgent: Color.urgent
  property color success: "#2ec27e"
  property color warning: "#ffaa00"
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top:true; bottom:true; left:true; right:true }
    color: "transparent"
    WlrLayershell.namespace: "com-compourri-windows-clone"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: root.scrim }

    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    BorderSurface {
      id: card
      width: Math.min(Style.space(640), panel.width * 0.92)
      height: Math.min(Style.space(640), panel.height * 0.92)
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
          if (root.confirmOpen && e.key===Qt.Key_Escape) { root.confirmOpen=false; e.accepted=true; return }
          if (e.key===Qt.Key_Escape) { root.dismiss(); e.accepted=true }
        }

        // Header
        RowLayout {
          Layout.fillWidth: true
          Text { text: "Windows Clone"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.heading; font.bold:true }
          Item { Layout.fillWidth: true }
          Text { text: root.omarchyDisk ? "Omarchy disk: "+root.omarchyDisk+" protected" : "⚠ Detecting Omarchy disk…"; color: root.omarchyDisk ? Util.alpha(root.foreground,0.6) : root.warning; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
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
        // Safety/script banners
        Rectangle {
          Layout.fillWidth: true
          visible: !root.scriptExists || !root.omarchyDisk
          color: root.urgent
          radius: Style.cornerRadius / 2
          height: visible ? warnCol.implicitHeight + Style.space(12) : 0
          ColumnLayout {
            id: warnCol
            anchors.fill: parent
            anchors.margins: Style.space(8)
            spacing: 2
            Text { visible: !root.scriptExists; text: root.scriptExistsMsg; color: "white"; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.Wrap; Layout.fillWidth: true }
            Text { visible: !root.omarchyDisk && root.scriptExists; text: "Omarchy disk not detected — Clone disabled until detected. Hit Refresh."; color: "white"; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.Wrap; Layout.fillWidth: true }
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

          Text { text: "Target WILL BE WIPED"; color: root.urgent; font.family: root.fontFamily; font.pixelSize: Style.font.title; font.bold:true }
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

        Toggle {
          id: guidToggle
          Layout.fillWidth: true
          label: "Preserve GUIDs"
          description: root.preserveGuids ? "on — for client PC (keeps Disk GUIDs)" : "off — randomize for keeping both disks connected"
          checked: root.preserveGuids
          onClicked: root.preserveGuids = !root.preserveGuids
        }

        // Actions
        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.sm
          Rectangle {
            Layout.fillWidth: true
            height: 3
            radius: 2
            color: Util.alpha(root.foreground, 0.15)
            visible: root.busy
            Rectangle {
              anchors.fill: parent
              color: root.statusColor
              radius: 2
              // simple indeterminate via opacity pulse — cheap but visible
              opacity: 0.85
            }
          }
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.sm
            Button {
              text: root.busy ? "Working…" : "Dry-run"
              enabled: !root.busy && root.scriptExists && !!root.omarchyDisk && root.sourcePath && root.targetPath && root.sourcePath!==root.targetPath
              onClicked: root.runDryRun()
            }
            Button {
              text: root.busy ? "Cloning…" : "Clone — WIPE TARGET"
              enabled: !root.busy && root.scriptExists && !!root.omarchyDisk && root.sourcePath && root.targetPath && root.sourcePath!==root.targetPath
              onClicked: root.requestClone()
            }
            Item { Layout.fillWidth: true }
            Text { text: root.statusText; color: root.statusColor; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.Wrap; Layout.fillWidth:true; Layout.maximumWidth: Style.space(380) }
          }
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

    // Confirm scrim (above card, below dialog)
    Rectangle {
      visible: root.confirmOpen
      anchors.fill: parent
      color: Util.alpha("black", 0.45)
      MouseArea { anchors.fill: parent; onClicked: root.confirmOpen = false }
    }
    // Confirm wipe dialog
    Rectangle {
      visible: root.confirmOpen
      anchors.centerIn: parent
      width: Math.min(Style.space(520), panel.width - Style.space(32))
      height: confirmCol.implicitHeight + Style.space(24)
      radius: root.cornerRadius
      color: root.background
      border.color: root.urgent
      border.width: 2
      ColumnLayout {
        id: confirmCol
        anchors.fill: parent
        anchors.margins: Style.space(16)
        spacing: Style.spacing.sm
        Text { text: "Confirm wipe — target WILL BE DESTROYED"; color: root.urgent; font.family: root.fontFamily; font.pixelSize: Style.font.title; font.bold: true; wrapMode: Text.Wrap; Layout.fillWidth: true }
        Text { text: "Source: " + root.sourcePath + "\nTarget: " + root.targetPath + "  ← ALL DATA LOST"; color: root.foreground; font.family: "monospace"; font.pixelSize: Style.font.caption; wrapMode: Text.Wrap; Layout.fillWidth: true }
        Text { text: "Preserve GUIDs: " + (root.preserveGuids ? "ON (for client PC)" : "OFF (randomize)"); color: Util.alpha(root.foreground,0.7); font.family: root.fontFamily; font.pixelSize: Style.font.caption; Layout.fillWidth: true }
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.sm
          Item { Layout.fillWidth: true }
          Button { text: "Cancel"; onClicked: root.confirmOpen = false }
          Button { text: "YES, WIPE & CLONE"; onClicked: root.runClone() }
        }
      }
      MouseArea { anchors.fill: parent; onClicked: {} }
    }
  }
}
