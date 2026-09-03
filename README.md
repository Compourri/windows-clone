# Windows Clone

Whole-disk Windows cloner for mismatched drive sizes - `EFI + MSR + NTFS + Recovery`. Recurring use case: `500G old -> 256G SSD` where data fits but `dd` fails.

Preserves `Disk GUID` + `Partition GUIDs` so cloned drive boots in client PC. Protects Omarchy system disk (`nvme0n1`) automatically. Handles `SATA` + rare `NVMe` targets, `2TB+` `GPT`.

`dd` is raw sector copy - target must be `>=` source. This does filesystem-aware clone: `sfdisk` scaled partition table + `ntfsclone`/`ntfsresize`/`dd` per partition + `rsync` fallback for dirty NTFS.

## Script

`clone-windows.sh` - `bash` `set -euo pipefail`, needs `sgdisk` (`gptfdisk`), `sfdisk` (`util-linux`), `ntfsclone`/`ntfsresize`/`mkntfs` (`ntfs-3g` + `ntfsprogs`).

```bash
sudo ./clone-windows.sh /dev/source /dev/target --dry-run
sudo ./clone-windows.sh /dev/sda /dev/sdb              # Type YES
sudo ./clone-windows.sh /dev/sda /dev/sdb --randomize-guids  # keep both disks
```

Checks `used < target usable` via `ntfsresize --info`, wipes target `sgdisk --zap-all`, replicates `GPT` with main NTFS shrunk to fill (`sgdisk --move-second-header`), clones `EFI fat32 -> dd`, `MSR -> dd`, `NTFS -> ntfsclone --overwrite + ntfsresize 100%` or `mkntfs + rsync -aHAX` for dirty.

Install deps on Omarchy/Arch:
```bash
sudo pacman -S gptfdisk ntfs-3g ntfsprogs
```

## Omarchy GUI (Quickshell)

Native Omarchy shell plugin `C` - `overlay` + `bar-widget`.

* Bar icon `󰋊` at top `right` before tray - click summons overlay.
* Also `omarchy-shell shell summon com.george.windows-clone '{}'`
* Overlay: `lsblk -J` source/target pickers (hides Omarchy disk), `Preserve GUIDs` toggle (`on` for client PC), `Dry-run` / `Clone` buttons (`pkexec` polkit), live log (`~/.local/state/clone-windows.log`), `sgdisk --verify` at end.

Install:

```bash
mkdir -p ~/.config/omarchy/plugins/com.george.windows-clone
cp omarchy-plugin/* ~/.config/omarchy/plugins/com.george.windows-clone/
omarchy plugin enable com.george.windows-clone
# icon appears right side - click or:
omarchy-shell shell summon com.george.windows-clone '{}'
```

Plugin enabled adds `bar.layout.right[0] = com.george.windows-clone` in `~/.config/omarchy/shell.json`.

## Repo layout

```
clone-windows.sh          # CLI cloner
omarchy-plugin/
  manifest.json           # schemaVersion 1, kinds ["overlay","bar-widget"]
  Clone.qml               # overlay GUI
  BarWidget.qml           # top bar icon
```

Original installed locations: `~/.local/bin/clone-windows.sh` and `~/.config/omarchy/plugins/com.george.windows-clone/`.

## License

MIT
