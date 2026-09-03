import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "com.george.windows-clone"
  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // hard-drive clone icon - use Clone text if glyph missing
    text: "󰋊"
    tooltipText: "Windows Clone - clone client drives"
    onPressed: {
      if (shell && typeof shell.summon === "function") shell.summon(manifest.id, "{}")
      else if (root.bar) root.bar.run("omarchy-shell shell summon com.george.windows-clone '{}'")
    }
  }
}
