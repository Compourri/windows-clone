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

  property string helperPath: "/usr/lib/windows-clone/windows-clone-helper"
  // Polkit action: com.compourri.windows-clone.pkexec (via org.freedesktop.policykit.exec.path annotation)
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
  property bool helperExists: true
  property string helperExistsMsg: ""
  // raw vs filtered logs + progress state
  property string rawLogText: ""
  property bool showRawLog: false
  property int rsyncPercent: 0
  property string rsyncSpeed: ""
  property string rsyncTransferred: ""
  property string rsyncElapsed: ""
  property string rsyncXfr: ""
  property string rsyncIrChk: ""

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

  // Check helper exists at startup
  Process {
    id: helperCheckProc
    command: ["test", "-x", "/usr/lib/windows-clone/windows-clone-helper"]
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      if (code !== 0) {
        root.helperExists = false
        root.helperExistsMsg = "Helper not found or not executable: /usr/lib/windows-clone/windows-clone-helper"
        root.statusText = root.helperExistsMsg
        root.statusColor = root.urgent
      } else {
        root.helperExists = true
        root.helperExistsMsg = ""
      }
    }
  }

  Component.onCompleted: { refreshDisks(); helperCheckProc.running = true }

  function _formatBytes(commaStr) {
    if (!commaStr) return ""
    var n = parseInt(String(commaStr).replace(/,/g,""))
    if (isNaN(n)) return commaStr
    if (n >= 1099511627776) return (n/1099511627776).toFixed(1) + " TiB"
    if (n >= 1073741824) return (n/1073741824).toFixed(1) + " GiB"
    if (n >= 1048576) return (n/1048576).toFixed(1) + " MiB"
    if (n >= 1024) return (n/1024).toFixed(1) + " KiB"
    return n + " B"
  }
  function _updateLogLive(outId, errId) {
    var raw = String(outId.text||"") + String(errId.text||"")
    root.rawLogText = raw
    // Normalize \r (rsync --info=progress2) to \n, then filter progress lines out of visible log
    var normalized = raw.replace(/\r/g, "\n")
    var lines = normalized.split("\n")
    var filtered = []
    // Keep last progress values; reset if not busy
    var lastPercent = root.rsyncPercent
    for (var i=0;i<lines.length;i++) {
      var line = lines[i]
      if (!line.trim()) continue
      // rsync --info=progress2: "  78,319,653,265  96%   19.13MB/s    1:05:05 (xfr#151668, ir-chk=1884/198256)"
      var rsyncM = line.match(/^\s*([\d,]+)\s+(\d+)%\s+([\d\.]+\s*[KMGT]?B\/s)\s+([\d:]+)\s+\(xfr#(\d+),/)
      if (rsyncM) {
        root.rsyncTransferred = _formatBytes(rsyncM[1])
        root.rsyncPercent = parseInt(rsyncM[2],10)
        root.rsyncSpeed = rsyncM[3].replace(/\s+/g,"")
        root.rsyncElapsed = rsyncM[4]
        root.rsyncXfr = rsyncM[5]
        var chk = line.match(/ir-chk=(\d+)\/(\d+)/)
        if (chk) root.rsyncIrChk = chk[1] + "/" + chk[2]
        continue
      }
      // ntfsclone " 45.67 percent completed"
      var pctM = line.match(/(\d+\.\d+)\s*percent completed/)
      if (pctM) {
        root.rsyncPercent = Math.round(parseFloat(pctM[1]))
        root.rsyncSpeed = ""
        continue
      }
      // Skip empty rsync summary lines that are just numbers without INFO/WARN prefix
      // Keep useful lines: INFO/WARN/ERROR, partition table, mkntfs, etc.
      filtered.push(line)
    }
    // Avoid unbounded growth: keep last 800 meaningful lines
    if (filtered.length > 800) filtered = filtered.slice(filtered.length - 800)
    var newText = filtered.join("\n")
    // Only bump seq if visible text changed (prevents thrashing on every progress tick)
    if (newText !== root.logText) {
      root.logText = newText
      root.logSeq++
      Qt.callLater(function(){ if (logView) logView.positionViewAtEnd() })
    } else if (lastPercent !== root.rsyncPercent) {
      // Still need to refresh progress bar even if log didn't change
      root.logSeq = root.logSeq // trigger progress binding without full log rebuild? Instead just ensure bar updates
    }
    // Keep progress bar in sync even when filtered log unchanged
    if (raw !== root.rawLogText) {
      // already updated rawLogText above
    }
  }
  function _visibleLogText() {
    return root.showRawLog ? root.rawLogText.replace(/\r/g, "\n") : root.logText
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
    if (!root.helperExists) { root.statusText=root.helperExistsMsg; root.statusColor=root.urgent; return }
    if (!root.sourcePath || !root.targetPath) { root.statusText="Pick source and target"; root.statusColor=root.warning; return }
    if (root.sourcePath === root.targetPath) { root.statusText="Source and target must differ"; root.statusColor=root.urgent; return }
    if (!root.omarchyDisk) { root.statusText="Omarchy disk not detected — cannot verify safety, refresh"; root.statusColor=root.warning; return }
    root.busy = true
    root.statusText = "Dry-run..."
    root.statusColor = Color.menu.text
    root.rsyncPercent = 0; root.rsyncSpeed=""; root.rsyncTransferred=""; root.rsyncElapsed=""; root.rsyncXfr=""; root.rsyncIrChk=""
    root.rawLogText = "Running: pkexec " + root.helperPath + " dry-run " + root.sourcePath + " " + root.targetPath + "\n"
    root.logText = root.rawLogText
    root.logSeq++
    dryRunProc.command = ["pkexec", root.helperPath, "dry-run", root.sourcePath, root.targetPath]
    dryRunProc.running = true
  }
  function requestClone() {
    if (!root.helperExists) { root.statusText=root.helperExistsMsg; root.statusColor=root.urgent; return }
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
    root.rsyncPercent = 0; root.rsyncSpeed=""; root.rsyncTransferred=""; root.rsyncElapsed=""; root.rsyncXfr=""; root.rsyncIrChk=""
    var extra = root.preserveGuids ? ["--yes"] : ["--randomize-guids", "--yes"]
    var cmdArgs = ["pkexec", root.helperPath, "clone", root.sourcePath, root.targetPath]
    for (var i=0; i<extra.length; i++) cmdArgs.push(extra[i])
    root.rawLogText = "Running: pkexec " + root.helperPath + " clone " + root.sourcePath + " " + root.targetPath + (extra.length?" "+extra.join(" "):"") + "\n"
    root.logText = root.rawLogText
    root.logSeq++
    cloneProc.command = cmdArgs
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
          visible: !root.helperExists || !root.omarchyDisk
          color: root.urgent
          radius: Style.cornerRadius / 2
          height: visible ? warnCol.implicitHeight + Style.space(12) : 0
          ColumnLayout {
            id: warnCol
            anchors.fill: parent
            anchors.margins: Style.space(8)
            spacing: 2
            Text { visible: !root.helperExists; text: root.helperExistsMsg; color: "white"; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.Wrap; Layout.fillWidth: true }
            Text { visible: !root.omarchyDisk && root.helperExists; text: "Omarchy disk not detected — Clone disabled until detected. Hit Refresh."; color: "white"; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.Wrap; Layout.fillWidth: true }
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
              enabled: !root.busy && root.helperExists && !!root.omarchyDisk && root.sourcePath && root.targetPath && root.sourcePath!==root.targetPath
              onClicked: root.runDryRun()
            }
            Button {
              text: root.busy ? "Cloning…" : "Clone — WIPE TARGET"
              enabled: !root.busy && root.helperExists && !!root.omarchyDisk && root.sourcePath && root.targetPath && root.sourcePath!==root.targetPath
              onClicked: root.requestClone()
            }
            Item { Layout.fillWidth: true }
            Text { text: root.statusText; color: root.statusColor; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.Wrap; Layout.fillWidth:true; Layout.maximumWidth: Style.space(380) }
          }
        }

        // Progress — rsync / ntfsclone
        BorderSurface {
          Layout.fillWidth: true
          visible: root.busy && root.rsyncPercent > 0
          radius: Style.cornerRadius / 2
          color: Util.alpha(Color.menu.background,0.96)
          borderSpec: Border.surfaceSpec("menu","border", Util.alpha(root.border,0.35), 1)
          padding: Style.space(8)
          ColumnLayout {
            id: progressCol
            anchors.fill: parent
            spacing: Style.spacing.sm
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.spacing.sm
              Text {
                text: root.rsyncPercent + "%"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }
              Item { Layout.fillWidth: true }
              Text {
                text: (root.rsyncTransferred ? root.rsyncTransferred + " • " : "") + (root.rsyncSpeed ? root.rsyncSpeed : "") + (root.rsyncElapsed ? " • " + root.rsyncElapsed : "") + (root.rsyncXfr ? " • xfr#" + root.rsyncXfr : "") + (root.rsyncIrChk ? " • chk " + root.rsyncIrChk : "")
                color: Util.alpha(root.foreground,0.7)
                font.family: "monospace"
                font.pixelSize: Style.font.caption
                elide: Text.ElideMiddle
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignRight
              }
            }
            Rectangle {
              Layout.fillWidth: true
              height: Style.space(10)
              radius: 5
              color: Util.alpha(root.foreground, 0.15)
              clip: true
              Rectangle {
                width: parent.width * Math.min(100, root.rsyncPercent) / 100
                height: parent.height
                radius: 5
                color: root.statusColor === root.warning ? root.warning : root.success
                Behavior on width { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
              }
            }
          }
        }

        // Log header with raw toggle
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.sm
          Text { text: root.showRawLog ? "Raw log — full output" : "Log — filtered"; color: Util.alpha(root.foreground,0.7); font.family: root.fontFamily; font.pixelSize: Style.font.caption; Layout.fillWidth: true }
          Button {
            text: root.showRawLog ? "Show filtered" : "Show raw"
            onClicked: root.showRawLog = !root.showRawLog
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
          // repopulate on log change — respects raw/filtered toggle
          Connections {
            target: root
            function onLogSeqChanged() {
              logModel.clear()
              var src = root.showRawLog ? root.rawLogText : root.logText
              // rawLog may contain \r, normalize for display
              src = String(src||"").replace(/\r/g, "\n")
              var lines = src.split("\n")
              // cap for performance
              if (lines.length > 1000) lines = lines.slice(lines.length - 1000)
              for (var i=0;i<lines.length;i++) {
                // skip empty trailing lines in raw view
                if (!root.showRawLog && !lines[i].trim()) continue
                logModel.append({text: lines[i]})
              }
            }
          }
          Connections {
            target: root
            function onShowRawLogChanged() {
              // rebuild view when toggling
              logModel.clear()
              var src = root.showRawLog ? root.rawLogText : root.logText
              src = String(src||"").replace(/\r/g, "\n")
              var lines = src.split("\n")
              if (lines.length > 1000) lines = lines.slice(lines.length - 1000)
              for (var i=0;i<lines.length;i++) {
                if (!root.showRawLog && !lines[i].trim()) continue
                logModel.append({text: lines[i]})
              }
              Qt.callLater(function(){ if (logView) logView.positionViewAtEnd() })
            }
          }
        }

        Text {
          Layout.fillWidth: true
          text: "Log: "+root.logPath+"  •  Helper: "+root.helperPath
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
      z: 10
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
    }
  }
}
