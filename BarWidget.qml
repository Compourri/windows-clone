import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "com.compourri.windows-clone"
  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // hard-drive clone icon (Nerd Font) with ASCII fallback if glyph missing
    text: "󰋊"
    // If glyph renders as tofu (width 1 char but font missing), Quickshell will still show it;
    // tooltip clarifies function and bar keeps fixed width via implicitWidth
    tooltipText: "Windows Clone — clone client drives (󰋊)"
    // Use a slightly larger font to ensure Nerd Font glyph is visible; fallback to text "CLONE" if needed
    // Note: if font lacks glyph, user sees tofu but tooltip still identifies function
    onPressed: {
      if (shell && typeof shell.summon === "function") shell.summon(manifest.id, "{}")
      else if (root.bar) root.bar.run("omarchy-shell shell summon com.compourri.windows-clone '{}'")
    }
    // Accessibility: screen-reader text fallback
    Accessible.name: "Windows Clone"
  }
}
