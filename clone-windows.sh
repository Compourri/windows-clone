#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# clone-windows.sh - Whole-disk Windows clone (EFI+MSR+NTFS+Recovery) with mismatched sizes
# Preserves Disk GUID + Partition GUIDs by default (cloned drive goes back to client PC)
# Handles recurring 500G -> 256G SSD where data fits but raw dd would fail.
# Protects Omarchy root disk (nvme0n1) unconditionally.
#
# Usage: sudo clone-windows.sh /dev/source /dev/target [--dry-run] [--randomize-guids] [--force]
# Example: sudo clone-windows.sh /dev/sda /dev/sdb
#          sudo clone-windows.sh /dev/nvme1n1 /dev/sda --dry-run

PROG="$(basename "$0")"
PRESERVE_GUIDS=1
DRY_RUN=0
FORCE=0
LOG_FILE="$HOME/.local/state/clone-windows.log"
mkdir -p "$(dirname "$LOG_FILE")"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

log() { echo -e "$@" | tee -a "$LOG_FILE"; }
die() { echo -e "${RED}ERROR:${NC} $*" | tee -a "$LOG_FILE" >&2; exit 1; }
warn() { echo -e "${YELLOW}WARN:${NC} $*" | tee -a "$LOG_FILE" >&2; }
info() { echo -e "${CYAN}INFO:${NC} $*" | tee -a "$LOG_FILE"; }
ok() { echo -e "${GREEN}OK:${NC} $*" | tee -a "$LOG_FILE"; }

usage() {
  cat <<EOF
Usage: sudo $PROG /dev/source /dev/target [options]

Clones whole Windows disk (all partitions) filesystem-aware for mismatched sizes.
Data must fit on target (you check before) - script verifies.

Arguments:
  /dev/source   Windows source disk (e.g. /dev/sda, /dev/nvme1n1)
  /dev/target   Destination disk (e.g. /dev/sdb) - WILL BE WIPED

Options:
  --dry-run            Show what would be done, no writes
  --randomize-guids    Don't preserve Disk/Partition GUIDs (for keeping both disks in same PC)
  --force              Allow targeting protected disks (still never Omarchy root)
  -h, --help           Show this

Notes:
  - Preserves GUIDs by default (cloned drive returns to client).
  - Supports normal SATA + rare NVMe targets.
  - Handles 2TB+ GPT via sgdisk --move-second-header.
  - Requires: sgdisk/gdisk, sfdisk (util-linux), partprobe, ntfsclone, ntfsresize, mkfs.vfat
EOF
  exit 0
}

# ---- parse args ----
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    --dry-run) DRY_RUN=1; shift ;;
    --randomize-guids) PRESERVE_GUIDS=0; shift ;;
    --force) FORCE=1; shift ;;
    --preserve-guids) PRESERVE_GUIDS=1; shift ;;
    -*) die "Unknown option: $1" ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]}"
[[ ${#POSITIONAL[@]} -eq 2 ]] || { usage; die "Need /dev/source and /dev/target"; }
SRC="$1"
TGT="$2"

[[ $EUID -eq 0 ]] || die "Run with sudo: sudo $PROG $SRC $TGT"
[[ -b "$SRC" ]] || die "Source not a block device: $SRC"
[[ -b "$TGT" ]] || die "Target not a block device: $TGT"
[[ "$SRC" != "$TGT" ]] || die "Source and target are same: $SRC"
# Resolve to disk (not partition)
# Detect whole disk vs partition using TYPE (disk vs part/crypt)
SRC_TYPE="$(lsblk -n -d -o TYPE "$SRC" 2>/dev/null || echo "")"
TGT_TYPE="$(lsblk -n -d -o TYPE "$TGT" 2>/dev/null || echo "")"
[[ "$SRC_TYPE" == "disk" ]] || die "Source must be whole disk (got TYPE=$SRC_TYPE): $SRC - did you pass a partition like ${SRC}1?"
[[ "$TGT_TYPE" == "disk" ]] || die "Target must be whole disk (got TYPE=$TGT_TYPE): $TGT"

# ---- protect Omarchy root disk ----
# Find root disk: / on /dev/mapper/root -> nvme0n1p2 -> nvme0n1 ; /boot on nvme0n1p1
OMARCHY_DISK=""
# Robust: find disk backing / (handles /dev/mapper/root[/@] -> dm-0 -> nvme0n1p2 -> nvme0n1)
ROOT_SRC="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
if [[ "$ROOT_SRC" == /dev/mapper/* ]]; then
  DM_NAME="$(basename "${ROOT_SRC%%\[*}")"
  # pkname of dm device's parent partition
  ROOT_PART="$(lsblk -n -o PKNAME "/dev/$DM_NAME" 2>/dev/null | head -1 || true)"
  if [[ -n "$ROOT_PART" ]]; then
    PARENT="$(lsblk -n -d -o PKNAME "/dev/$ROOT_PART" 2>/dev/null | head -1 || true)"
    if [[ -n "$PARENT" ]]; then OMARCHY_DISK="/dev/$PARENT"
    else OMARCHY_DISK="/dev/$ROOT_PART"
    fi
    # if still partition, go one more level
    if [[ "$(lsblk -n -d -o TYPE "$OMARCHY_DISK" 2>/dev/null)" != "disk" ]]; then
      P2="$(lsblk -n -d -o PKNAME "$OMARCHY_DISK" 2>/dev/null | head -1 || true)"
      [[ -n "$P2" ]] && OMARCHY_DISK="/dev/$P2"
    fi
  fi
elif [[ -n "$ROOT_SRC" && -b "${ROOT_SRC%%\[*}" ]]; then
  DEV="${ROOT_SRC%%\[*}"
  P="$(lsblk -n -d -o PKNAME "$DEV" 2>/dev/null | head -1 || true)"
  [[ -n "$P" ]] && OMARCHY_DISK="/dev/$P" || OMARCHY_DISK="$DEV"
fi
# Fallback via /boot
if [[ -z "$OMARCHY_DISK" || ! -b "$OMARCHY_DISK" ]]; then
  BOOT_SRC="$(findmnt -n -o SOURCE /boot 2>/dev/null || true)"
  if [[ -n "$BOOT_SRC" && -b "$BOOT_SRC" ]]; then
    P="$(lsblk -n -d -o PKNAME "$BOOT_SRC" 2>/dev/null | head -1 || true)"
    [[ -n "$P" ]] && OMARCHY_DISK="/dev/$P" || OMARCHY_DISK="${BOOT_SRC%p1}"
  fi
fi
# Final fallback
if [[ -z "$OMARCHY_DISK" || ! -b "$OMARCHY_DISK" ]]; then OMARCHY_DISK="/dev/nvme0n1"; fi
# Canonicalize
SRC_REAL="$(readlink -f "$SRC")"
TGT_REAL="$(readlink -f "$TGT")"
OMARCHY_REAL="$(readlink -f "$OMARCHY_DISK" 2>/dev/null || echo "$OMARCHY_DISK")"

info "Detected Omarchy disk: $OMARCHY_REAL (protected)"
if [[ "$TGT_REAL" == "$OMARCHY_REAL" ]]; then
  die "Target is Omarchy system disk ($OMARCHY_REAL)! Refusing even with --force. Choose another target."
fi
if [[ "$SRC_REAL" == "$OMARCHY_REAL" ]]; then
  warn "Source is Omarchy disk ($OMARCHY_REAL) - cloning your own system, not a Windows client drive?"
fi

# Check tools
for cmd in sgdisk sfdisk partprobe ntfsclone ntfsresize blkid lsblk parted blockdev; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required tool: $cmd (install gdisk util-linux ntfsprogs)"
done

# ---- info ----
log "=== $PROG $(date -Iseconds) ==="
log "Source: $SRC_REAL   Target: $TGT_REAL   preserve_guids=$PRESERVE_GUIDS dry_run=$DRY_RUN"
log ""
info "Source layout:"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,PARTUUID,MODEL "$SRC_REAL" 2>&1 | tee -a "$LOG_FILE" || true
echo "" | tee -a "$LOG_FILE"
parted -s "$SRC_REAL" unit MiB print 2>&1 | tee -a "$LOG_FILE" || true
sgdisk --print "$SRC_REAL" 2>&1 | tee -a "$LOG_FILE" || true
echo "" | tee -a "$LOG_FILE"
info "Target layout (BEFORE):"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MODEL "$TGT_REAL" 2>&1 | tee -a "$LOG_FILE" || true
parted -s "$TGT_REAL" unit MiB print 2>&1 | tee -a "$LOG_FILE" || true
echo "" | tee -a "$LOG_FILE"

SRC_SIZE="$(blockdev --getsize64 "$SRC_REAL")"
TGT_SIZE="$(blockdev --getsize64 "$TGT_REAL")"
SRC_HUMAN="$(lsblk -n -d -o SIZE "$SRC_REAL")"
TGT_HUMAN="$(lsblk -n -d -o SIZE "$TGT_REAL")"
info "Size: source $SRC_HUMAN ($SRC_SIZE bytes) -> target $TGT_HUMAN ($TGT_SIZE bytes)"

# ---- check mounted (unmount before ntfsresize check, even in dry-run we try) ----
if findmnt -n -o TARGET "$SRC_REAL" >/dev/null 2>&1; then warn "Source disk has mounted filesystem"; fi
for part in $(lsblk -n -r -o NAME "$SRC_REAL" 2>/dev/null | tail -n +2 || true); do
  dev="/dev/$part"
  if findmnt -n "$dev" >/dev/null 2>&1; then
    info "Unmounting source $dev $(findmnt -n -o TARGET "$dev" 2>/dev/null)"
    umount -f "$dev" 2>&1 | tee -a "$LOG_FILE" || warn "Failed to umount $dev - close Explorer/GNOME Disks (will try ntfsresize anyway)"
  fi
done
for part in $(lsblk -n -r -o NAME "$TGT_REAL" 2>/dev/null | tail -n +2 || true); do
  dev="/dev/$part"
  if findmnt -n "$dev" >/dev/null 2>&1; then
    info "Unmounting target $dev"
    umount -f "$dev" 2>&1 | tee -a "$LOG_FILE" || true
  fi
done

# ---- data-fits check ----
# Sum fixed partitions (everything except main NTFS msftdata Basic data partition)
# Heuristic: largest NTFS is main data partition
info "Checking data fits on target..."
SRC_PARTS=()
while IFS= read -r line; do SRC_PARTS+=("$line"); done < <(lsblk -n -r -o NAME,FSTYPE,SIZE,TYPE "$SRC_REAL" | awk '$4=="part" {print $1":"$2":"$3}')
MAIN_NTFS=""
MAIN_SIZE=0
for entry in "${SRC_PARTS[@]}"; do
  IFS=':' read -r name fstype size <<< "$entry"
  if [[ "$fstype" == "ntfs" ]]; then
    # get bytes
    b="$(blockdev --getsize64 "/dev/$name" 2>/dev/null || echo 0)"
    if (( b > MAIN_SIZE )); then MAIN_SIZE=$b; MAIN_NTFS="/dev/$name"; fi
  fi
done
if [[ -z "$MAIN_NTFS" ]]; then warn "No NTFS main partition found - will do raw dd for all"; fi

FIXED_SUM=0
for entry in "${SRC_PARTS[@]}"; do
  IFS=':' read -r name fstype size <<< "$entry"
  dev="/dev/$name"
  [[ "$dev" == "$MAIN_NTFS" ]] && continue
  b="$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)"
  FIXED_SUM=$((FIXED_SUM + b))
done
# Add 4M alignment slop
FIXED_SUM=$((FIXED_SUM + 4*1024*1024))
info "Fixed partitions total ~ $((FIXED_SUM/1024/1024)) MiB, main NTFS $MAIN_NTFS size $((MAIN_SIZE/1024/1024)) MiB"

if [[ -n "$MAIN_NTFS" ]]; then
  # ntfsresize --info gives used
  if ! NTFS_INFO="$(ntfsresize --force --info "$MAIN_NTFS" 2>&1)"; then
    warn "ntfsresize --info failed on $MAIN_NTFS, assuming ~80% used"
    NTFS_INFO=""
  fi
  echo "$NTFS_INFO" | tee -a "$LOG_FILE" || true
  # Parse "You might resize at ..." or "Volume size :"
  USED_BYTES=""
  if echo "$NTFS_INFO" | grep -q "might resize"; then
    # line: You might resize at 123456789012 bytes or 123456 MB
    USED_BYTES="$(echo "$NTFS_INFO" | grep "might resize" | grep -oP '\d+(?= bytes)' | head -1 || true)"
  fi
  if [[ -z "$USED_BYTES" ]]; then
    # fallback: use 90% of main if cannot parse, or use minimal
    USED_BYTES=""
  fi
  # Alternative: use ntfscluster or just check no-fail - if used_bytes unknown, skip strict check but warn
  TGT_USABLE_FOR_MAIN=$((TGT_SIZE - FIXED_SUM - 16*1024*1024)) # 16M slop
  info "Target usable for main NTFS: $((TGT_USABLE_FOR_MAIN/1024/1024)) MiB (target $((TGT_SIZE/1024/1024)) - fixed $((FIXED_SUM/1024/1024)) MiB)"
  if [[ -n "$USED_BYTES" && "$USED_BYTES" -gt 0 ]]; then
    info "Main NTFS minimal required (data): $((USED_BYTES/1024/1024)) MiB"
    if (( USED_BYTES > TGT_USABLE_FOR_MAIN )); then
      die "Data does NOT fit! Need $((USED_BYTES/1024/1024)) MiB but target has $((TGT_USABLE_FOR_MAIN/1024/1024)) MiB for main. Choose larger target."
    else
      ok "Data fits: $((USED_BYTES/1024/1024)) MiB needed < $((TGT_USABLE_FOR_MAIN/1024/1024)) MiB available"
    fi
  else
    warn "Could not determine exact used bytes - relying on your guarantee that data fits. Will attempt ntfsclone."
    if (( MAIN_SIZE > TGT_USABLE_FOR_MAIN + 50*1024*1024*1024 )); then
      warn "Main partition raw size $((MAIN_SIZE/1024/1024)) MiB much larger than target usable - but ntfsclone will shrink if data fits."
    fi
  fi
fi

# ---- confirm ----
echo "" | tee -a "$LOG_FILE"
echo -e "${RED}WARNING: Target $TGT_REAL ($TGT_HUMAN) WILL BE WIPED!${NC}" | tee -a "$LOG_FILE"
echo -e "Source $SRC_REAL ($SRC_HUMAN) -> Target $TGT_REAL ($TGT_HUMAN)  GUIDs preserve=$PRESERVE_GUIDS" | tee -a "$LOG_FILE"
if [[ $DRY_RUN -eq 1 ]]; then
  warn "DRY-RUN - no writes will be done"
else
  read -rp "Type YES to continue: " confirm
  [[ "$confirm" == "YES" ]] || die "Aborted (must type YES)"
fi

# ---- wipe and replicate GPT ----
info "Wiping target $TGT_REAL ..."
if [[ $DRY_RUN -eq 0 ]]; then
  sgdisk --zap-all "$TGT_REAL" 2>&1 | tee -a "$LOG_FILE"
  sgdisk --clear "$TGT_REAL" 2>&1 | tee -a "$LOG_FILE" || true
else
  log "[dry-run] sgdisk --zap-all $TGT_REAL"
fi

info "Replicating partition table scaled for mismatched sizes..."
# Dump source partitions with sfdisk
TMPDIR="$(mktemp -d)"
SRC_DUMP="$TMPDIR/source.dump"
TGT_DUMP="$TMPDIR/target.dump"
sfdisk -d "$SRC_REAL" > "$SRC_DUMP" 2>&1 || die "sfdisk -d failed"
cat "$SRC_DUMP" | tee -a "$LOG_FILE"

# Preserve disk GUID if requested
SRC_GUID="$(grep -i "label-id" "$SRC_DUMP" | head -1 | awk '{print $2}' || true)"
# Build new dump: keep start/size for all except main NTFS, main gets remainder
# Parse: device : start= X, size= Y, type=..., uuid=..., name=..., attrs=...
# Use python for robust parsing and size calc
if ! python3 <<PY 2>&1 | tee -a "$LOG_FILE"; then
import re, sys
src_dump="$SRC_DUMP"
tgt_dump="$TGT_DUMP"
src_size=int("$SRC_SIZE")
tgt_size=int("$TGT_SIZE")
sector=512

# read dump
lines=open(src_dump).read().splitlines()
header=[]
parts=[]
for l in lines:
    if l.startswith("label:") or l.startswith("label-id:") or l.startswith("device:") or l.startswith("unit:") or l.startswith("first-lba:") or l.startswith("last-lba:"):
        header.append(l)
    elif re.match(r'^\s*/dev/', l):
        parts.append(l)

# get source target sizes in sectors
tgt_sectors=tgt_size//sector
# find largest partition (main NTFS) by size
def parse_size(p):
    m=re.search(r'size=\s*(\d+)', p)
    return int(m.group(1)) if m else 0
idx_main=max(range(len(parts)), key=lambda i: parse_size(parts[i])) if parts else -1

# compute fixed sum sectors
fixed_sectors=sum(parse_size(p) for i,p in enumerate(parts) if i!=idx_main)
# alignment: keep starts as-is for first partitions, but adjust main size to fill
# We keep start of main as original start, size = tgt_sectors - start_main - trailing_reserved - sum of later parts?
# Simpler: keep start/size for all before main, main gets remaining minus sizes of parts after main
if idx_main>=0:
    # starts
    # Find start of main
    m=re.search(r'start=\s*(\d+)', parts[idx_main])
    start_main=int(m.group(1)) if m else 0
    # sum sizes of parts after main (recovery)
    after_sectors=sum(parse_size(p) for i,p in enumerate(parts) if i>idx_main)
    # reserve 33 sectors for backup GPT
    reserved=33
    new_main_size=tgt_sectors - start_main - after_sectors - reserved
    if new_main_size < 10*1024*1024*2: # <10G
        print(f"ERROR: target too small, new main size {new_main_size} sectors too small", file=sys.stderr)
        sys.exit(1)
    # patch main line
    parts[idx_main]=re.sub(r'size=\s*\d+', f'size= {new_main_size}', parts[idx_main])
    print(f"Main partition index {idx_main} new size {new_main_size} sectors ({new_main_size*sector//1024//1024} MiB)", file=sys.stderr)

# handle GUID preservation
preserve=int("$PRESERVE_GUIDS")
new_guid="$SRC_GUID"
if preserve:
    # keep label-id as source
    pass
else:
    # will be randomized later, keep placeholder
    pass

# write tgt dump
with open(tgt_dump,'w') as f:
    for h in header:
        if h.startswith("label-id:") and preserve and new_guid:
            f.write(f"label-id: {new_guid}\n")
        elif h.startswith("last-lba:"):
            f.write(f"last-lba: {tgt_sectors-1}\n")
        else:
            f.write(h+"\n")
    for p in parts:
        f.write(p+"\n")

print(f"Wrote {tgt_dump} with {len(parts)} partitions, tgt_sectors {tgt_sectors}")
PY
  die "Python sizing failed - aborting"
fi

cat "$TGT_DUMP" | tee -a "$LOG_FILE"

if [[ $DRY_RUN -eq 0 ]]; then
  sfdisk --force "$TGT_REAL" < "$TGT_DUMP" 2>&1 | tee -a "$LOG_FILE" || die "sfdisk restore failed"
  sgdisk --move-second-header "$TGT_REAL" 2>&1 | tee -a "$LOG_FILE" || true
  if [[ $PRESERVE_GUIDS -eq 0 ]]; then
    info "Randomizing GUIDs (both disks may stay connected)"
    sgdisk --randomize-guids "$TGT_REAL" 2>&1 | tee -a "$LOG_FILE" || true
  else
    info "Preserved Disk/Partition GUIDs from source (for client PC)"
    # sfdisk already preserved partition UUIDs via dump; ensure
    sgdisk --print "$TGT_REAL" 2>&1 | tee -a "$LOG_FILE" || true
  fi
  partprobe "$TGT_REAL" 2>&1 | tee -a "$LOG_FILE" || true
  udevadm settle 2>&1 | tee -a "$LOG_FILE" || true
  sleep 1
else
  log "[dry-run] sfdisk $TGT_REAL < $TGT_DUMP"
  log "[dry-run] sgdisk --move-second-header $TGT_REAL"
fi

# ---- per-partition clone ----
info "Cloning partitions filesystem-aware..."
# Map partitions: source N -> target N (same order/count)
SRC_PART_LIST=($(lsblk -n -r -o NAME "$SRC_REAL" | awk -v d="$(basename "$SRC_REAL")" '$1!=d'))
TGT_PART_LIST=($(lsblk -n -r -o NAME "$TGT_REAL" | awk -v d="$(basename "$TGT_REAL")" '$1!=d'))

if [[ $DRY_RUN -eq 1 ]]; then
  # Dry-run: synthesize target partition names (disk prefix + number)
  # Need correct p1 vs 1 suffix: nvme/mmcblk use 'p1', sda uses '1'
  TGT_PART_LIST=()
  for i in "${!SRC_PART_LIST[@]}"; do
    idx=$((i+1))
    if [[ "$TGT_REAL" == *nvme* || "$TGT_REAL" == *mmcblk* ]]; then
      TGT_PART_LIST+=("$(basename "$TGT_REAL")p${idx}")
    else
      TGT_PART_LIST+=("$(basename "$TGT_REAL")${idx}")
    fi
  done
else
  if [[ ${#SRC_PART_LIST[@]} -ne ${#TGT_PART_LIST[@]} ]]; then
    die "Partition count mismatch source ${#SRC_PART_LIST[@]} vs target ${#TGT_PART_LIST[@]} (sfdisk may have failed)"
  fi
fi
for i in "${!SRC_PART_LIST[@]}"; do
  idx=$((i+1))
  sdev="/dev/${SRC_PART_LIST[$i]}"
  # In dry-run, tdev name is synthetic; in real run it's real lsblk
  if [[ $DRY_RUN -eq 1 ]]; then
    tdev="/dev/${TGT_PART_LIST[$i]}"
  else
    tdev="/dev/${TGT_PART_LIST[$i]}"
  fi
  fstype="$(blkid -o value -s TYPE "$sdev" 2>/dev/null || echo "")"
  parttype="$(blkid -o value -s PART_ENTRY_TYPE "$sdev" 2>/dev/null || echo "")"
  label="$(blkid -o value -s LABEL "$sdev" 2>/dev/null || echo "")"
  info "[$idx/${#SRC_PART_LIST[@]}] $sdev ($fstype, $parttype, label=$label) -> $tdev"
  if [[ $DRY_RUN -eq 1 ]]; then
    log "[dry-run] would clone $sdev -> $tdev (fstype $fstype)"
    continue
  fi
  case "$fstype" in
    vfat)
      info "  FAT32 EFI -> dd"
      dd if="$sdev" of="$tdev" bs=64K status=progress conv=fsync 2>&1 | tee -a "$LOG_FILE"
      ;;
    ntfs)
      info "  NTFS -> ntfsclone --overwrite"
      if ! ntfsclone --overwrite "$tdev" "$sdev" 2>&1 | tee -a "$LOG_FILE"; then
        die "ntfsclone failed on $sdev -> $tdev"
      fi
      # If this is the main data partition (largest), resize to fill
      if [[ "$sdev" == "$MAIN_NTFS" ]]; then
        info "  Resizing main NTFS to fill partition (ntfsresize 100%)"
        ntfsresize --force --size 100% "$tdev" 2>&1 | tee -a "$LOG_FILE" || warn "ntfsresize failed - filesystem may still be smaller"
      fi
      ;;
    "")
      # MSR or unknown raw (no fstype)
      info "  Raw/MSR -> dd"
      dd if="$sdev" of="$tdev" bs=64K status=progress conv=fsync 2>&1 | tee -a "$LOG_FILE"
      ;;
    *)
      warn "  Unknown fstype $fstype, using dd"
      dd if="$sdev" of="$tdev" bs=64K status=progress conv=fsync 2>&1 | tee -a "$LOG_FILE"
      ;;
  esac
  sync
done

# ---- verify ----
info "Verifying target..."
sgdisk --verify "$TGT_REAL" 2>&1 | tee -a "$LOG_FILE" || warn "sgdisk verify warnings"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,PARTUUID "$TGT_REAL" 2>&1 | tee -a "$LOG_FILE" || true
parted -s "$TGT_REAL" unit MiB print 2>&1 | tee -a "$LOG_FILE" || true
for tpart in "${TGT_PART_LIST[@]}"; do
  tdev="/dev/$tpart"
  fstype="$(blkid -o value -s TYPE "$tdev" 2>/dev/null || true)"
  if [[ "$fstype" == "ntfs" ]]; then
    ntfsresize --force --info "$tdev" 2>&1 | tee -a "$LOG_FILE" || true
  fi
done

ok "Clone complete: $SRC_REAL -> $TGT_REAL"
log "Log: $LOG_FILE"
log "Next: Install $TGT_REAL in client PC and boot. If Windows shows 'Preparing Automatic Repair', boot WinPE USB and run: bcdboot C:\\Windows /s S: /f UEFI  (where S: is EFI partition)"
if [[ $DRY_RUN -eq 1 ]]; then ok "Dry-run finished - no data written"; fi

rm -rf "$TMPDIR"
