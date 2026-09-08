#!/usr/bin/env bash
set -euo pipefail
# Keep default IFS (space, tab, newline); use mapfile/while-read for newline-only splitting where needed

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
ASSUME_YES=0
# Log to invoking user's HOME even when run via sudo/pkexec (GUI expects ~/.local/state/clone-windows.log)
_REAL_HOME="$HOME"
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  _H="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)"
  [[ -n "$_H" && -d "$_H" ]] && _REAL_HOME="$_H" || _REAL_HOME="/home/$SUDO_USER"
fi
LOG_FILE="$_REAL_HOME/.local/state/clone-windows.log"
# Also keep a root copy when invoked via sudo so pkexec logs are not lost
LOG_FILE_ROOT="/root/.local/state/clone-windows.log"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
mkdir -p "$(dirname "$LOG_FILE_ROOT")" 2>/dev/null || true
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  chown "$SUDO_USER:" "$(dirname "$LOG_FILE")" 2>/dev/null || true
  touch "$LOG_FILE" 2>/dev/null && chown "$SUDO_USER:" "$LOG_FILE" 2>/dev/null || true
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# Helper: append to root log copy when running via sudo/pkexec (GUI reads user log, CLI may need root log)
_dual_append() {
  [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" && "$LOG_FILE" != "$LOG_FILE_ROOT" ]] && printf "%s\n" "$*" >> "$LOG_FILE_ROOT" 2>/dev/null || true
}
log() { echo -e "$@" | tee -a "$LOG_FILE"; _dual_append "$@"; }
die() { echo -e "${RED}ERROR:${NC} $*" | tee -a "$LOG_FILE" >&2; _dual_append "${RED}ERROR:${NC} $*"; exit 1; }
warn() { echo -e "${YELLOW}WARN:${NC} $*" | tee -a "$LOG_FILE" >&2; _dual_append "${YELLOW}WARN:${NC} $*"; }
info() { echo -e "${CYAN}INFO:${NC} $*" | tee -a "$LOG_FILE"; _dual_append "${CYAN}INFO:${NC} $*"; }
ok() { echo -e "${GREEN}OK:${NC} $*" | tee -a "$LOG_FILE"; _dual_append "${GREEN}OK:${NC} $*"; }

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
  --force              Deprecated alias for --yes (bypass interactive confirmation; Omarchy disk always blocked)
  -y, --yes            Bypass interactive YES prompt (for GUI/pkexec - caller must have confirmed)
  -h, --help           Show this

Notes:
  - Preserves GUIDs by default (cloned drive returns to client).
  - Supports normal SATA + rare NVMe targets.
  - Handles 2TB+ GPT via sgdisk --move-second-header; logical sector mismatch (512 vs 4096) is detected and warned.
  - Requires: sgdisk/gdisk, sfdisk, partprobe, ntfsclone, ntfsresize, mkntfs, mkfs.vfat, blkid, lsblk, parted, blockdev, udevadm, python3, rsync (fallback), ntfsfix (fallback)
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
    --force) FORCE=1; ASSUME_YES=1; shift ;;
    -y|--yes|--assume-yes) ASSUME_YES=1; shift ;;
    --preserve-guids) PRESERVE_GUIDS=1; shift ;;
    -*) die "Unknown option: $1" ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]}"
[[ ${#POSITIONAL[@]} -eq 2 ]] || { usage; die "Need /dev/source and /dev/target"; }
if [[ $FORCE -eq 1 ]]; then warn "--force is now alias for --yes (bypass interactive confirmation; Omarchy disk remains blocked)"; fi
if [[ $ASSUME_YES -eq 1 && $DRY_RUN -eq 1 ]]; then warn "--yes ignored with --dry-run (no writes)"; fi
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
  DM_DEV="$(readlink -f "/dev/$DM_NAME" 2>/dev/null || echo "/dev/$DM_NAME")"
  # pkname of dm device's parent partition - try DM_DEV then fallback
  ROOT_PART="$(lsblk -n -o PKNAME "$DM_DEV" 2>/dev/null | head -1 || true)"
  [[ -z "$ROOT_PART" ]] && ROOT_PART="$(lsblk -n -o PKNAME "/dev/$DM_NAME" 2>/dev/null | head -1 || true)"
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
# Final fallback - no hardcode, leave empty if detection fails
if [[ -z "$OMARCHY_DISK" || ! -b "$OMARCHY_DISK" ]]; then
  [[ -n "$OMARCHY_DISK" ]] && warn "Omarchy disk detection uncertain ($OMARCHY_DISK), skipping fallback"
  OMARCHY_DISK=""
fi
# Canonicalize
SRC_REAL="$(readlink -f "$SRC")"
TGT_REAL="$(readlink -f "$TGT")"
if [[ -n "$OMARCHY_DISK" ]]; then
  OMARCHY_REAL="$(readlink -f "$OMARCHY_DISK" 2>/dev/null || echo "$OMARCHY_DISK")"
else
  OMARCHY_REAL=""
fi

if [[ -n "$OMARCHY_REAL" ]]; then
  info "Detected Omarchy disk: $OMARCHY_REAL (protected)"
else
  warn "Could not detect Omarchy disk - no automatic protection. Verify target selection."
fi
if [[ -n "$OMARCHY_REAL" && "$TGT_REAL" == "$OMARCHY_REAL" ]]; then
  die "Target is Omarchy system disk ($OMARCHY_REAL)! Refusing even with --force. Choose another target."
fi
if [[ -n "$OMARCHY_REAL" && "$SRC_REAL" == "$OMARCHY_REAL" ]]; then
  warn "Source is Omarchy disk ($OMARCHY_REAL) - cloning your own system, not a Windows client drive?"
fi

# Check tools
for cmd in sgdisk sfdisk partprobe ntfsclone ntfsresize blkid lsblk parted blockdev udevadm python3 mkfs.vfat mkntfs mount umount; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required tool: $cmd (install gdisk util-linux ntfsprogs dosfstools ntfs-3g python3)"
done
# rsync/ntfsfix are optional (dirty NTFS fallback); warn if missing
if ! command -v rsync >/dev/null 2>&1; then
  warn "rsync not found — dirty NTFS fallback (mkntfs+rsync) will be unavailable; install rsync for full resilience"
fi
if ! command -v ntfsfix >/dev/null 2>&1; then
  warn "ntfsfix not found — dirty NTFS fallback will be less robust; install ntfs-3g"
fi

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
# Use findmnt -S (source) to detect mounts by device, including UUID mounts; plain findmnt without -S matches target
if findmnt -n -o TARGET -S "$SRC_REAL" >/dev/null 2>&1; then warn "Source disk has mounted filesystem"; fi
while IFS= read -r part; do
  [[ -z "$part" ]] && continue
  dev="/dev/$part"
  if findmnt -n -o TARGET -S "$dev" >/dev/null 2>&1; then
    info "Unmounting source $dev $(findmnt -n -o TARGET -S "$dev" 2>/dev/null)"
    umount -f "$dev" 2>&1 | tee -a "$LOG_FILE" || warn "Failed to umount $dev - close Explorer/GNOME Disks (will try ntfsresize anyway)"
  fi
done < <(lsblk -n -r -o NAME "$SRC_REAL" 2>/dev/null | tail -n +2 || true)
while IFS= read -r part; do
  [[ -z "$part" ]] && continue
  dev="/dev/$part"
  if findmnt -n -o TARGET -S "$dev" >/dev/null 2>&1; then
    info "Unmounting target $dev $(findmnt -n -o TARGET -S "$dev" 2>/dev/null)"
    umount -f "$dev" 2>&1 | tee -a "$LOG_FILE" || true
  fi
done < <(lsblk -n -r -o NAME "$TGT_REAL" 2>/dev/null | tail -n +2 || true)

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
elif [[ $ASSUME_YES -eq 1 ]]; then
  info "Confirmed via --yes/--force (GUI already confirmed) - proceeding without interactive prompt"
else
  # Fail closed when no TTY and no explicit --yes (prevents GUI pkexec hang on anon_pipe_read)
  if [[ ! -t 0 ]]; then
    die "No TTY and --yes not given - refusing to wait for interactive input. Re-run with --yes or from a terminal and type YES."
  fi
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
TMPDIR="$(mktemp -d)" || die "mktemp failed"
trap 'rm -rf "${TMPDIR:-}"' EXIT INT TERM
SRC_DUMP="$TMPDIR/source.dump"
TGT_DUMP="$TMPDIR/target.dump"
sfdisk -d "$SRC_REAL" > "$SRC_DUMP" 2>&1 || die "sfdisk -d failed"
cat "$SRC_DUMP" | tee -a "$LOG_FILE"

# Preserve disk GUID if requested
SRC_GUID="$(grep -i "label-id" "$SRC_DUMP" | head -1 | awk '{print $2}' || true)"
# Build new dump: keep start/size for all except main NTFS, main gets remainder
# Parse: device : start= X, size= Y, type=..., uuid=..., name=..., attrs=...
# Use python for robust parsing and size calc
# Detect logical sector size (512 vs 4096)
SECTOR_SIZE="$(blockdev --getss "$SRC_REAL" 2>/dev/null || echo 512)"
[[ "$SECTOR_SIZE" =~ ^[0-9]+$ ]] || SECTOR_SIZE=512
# Validate target sector size matches (warn if mismatch)
TGT_SECTOR_SIZE="$(blockdev --getss "$TGT_REAL" 2>/dev/null || echo "$SECTOR_SIZE")"
if [[ "$SECTOR_SIZE" != "$TGT_SECTOR_SIZE" ]]; then
  warn "Sector size mismatch: source $SECTOR_SIZE vs target $TGT_SECTOR_SIZE - assuming source size"
fi
export SRC_DUMP TGT_DUMP SRC_SIZE TGT_SIZE SECTOR_SIZE SRC_GUID PRESERVE_GUIDS
if ! python3 <<'PY' 2>&1 | tee -a "$LOG_FILE"; then
import os, re, sys
src_dump=os.environ["SRC_DUMP"]
tgt_dump=os.environ["TGT_DUMP"]
src_size=int(os.environ["SRC_SIZE"])
tgt_size=int(os.environ["TGT_SIZE"])
sector=int(os.environ["SECTOR_SIZE"])
src_guid=os.environ.get("SRC_GUID","")
preserve=int(os.environ.get("PRESERVE_GUIDS","1"))

# read dump
lines=open(src_dump).read().splitlines()
header=[]
parts=[]
for l in lines:
    if l.startswith("label:") or l.startswith("label-id:") or l.startswith("device:") or l.startswith("unit:") or l.startswith("first-lba:") or l.startswith("last-lba:") or l.startswith("sector-size:"):
        header.append(l)
    elif re.match(r'^\s*/dev/', l):
        parts.append(l)

# get source target sizes in sectors
tgt_sectors=tgt_size//sector
# find main NTFS (Basic data partition EBD0A0A2-...) by size; fallback to largest
def parse_size(p):
    m=re.search(r'size=\s*(\d+)', p)
    return int(m.group(1)) if m else 0
def is_basic_data(p):
    return "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7" in p.upper()
basic_indices=[i for i,p in enumerate(parts) if is_basic_data(p)]
if basic_indices:
    idx_main=max(basic_indices, key=lambda i: parse_size(parts[i]))
else:
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
    # fix starts of partitions after main - move them contiguously after resized main
    # avoids overlap when main grows (e.g. same-size clone filling slack) or gap when shrinking
    prev_end = start_main + new_main_size
    for j in range(idx_main+1, len(parts)):
        old_start_m = re.search(r'start=\s*(\d+)', parts[j])
        old_start = int(old_start_m.group(1)) if old_start_m else 0
        if old_start != prev_end:
            print(f"  Adjusting partition {j+1} start {old_start} -> {prev_end} (after resize)", file=sys.stderr)
            parts[j] = re.sub(r'start=\s*\d+', f'start= {prev_end}', parts[j], count=1)
        m2 = re.search(r'size=\s*(\d+)', parts[j])
        sz = int(m2.group(1)) if m2 else 0
        prev_end += sz
    # sanity: last partition must fit within disk (leave 33 for backup GPT)
    if prev_end + reserved > tgt_sectors:
        print(f"ERROR: partitions exceed target: last end {prev_end} + reserved {reserved} > tgt {tgt_sectors}", file=sys.stderr)
        sys.exit(1)

# handle GUID preservation (vars already from environ)
new_guid=src_guid
if preserve:
    # keep label-id as source
    pass
else:
    # will be randomized later, keep placeholder
    pass

# write tgt dump (preserve sector-size if present, update last-lba for target size)
with open(tgt_dump,'w') as f:
    has_sector_size=False
    for h in header:
        if h.startswith("sector-size:"):
            has_sector_size=True
            f.write(f"sector-size: {sector}\n")
        elif h.startswith("label-id:") and preserve and new_guid:
            f.write(f"label-id: {new_guid}\n")
        elif h.startswith("last-lba:"):
            f.write(f"last-lba: {tgt_sectors-1}\n")
        else:
            f.write(h+"\n")
    # ensure sector-size present for explicitness
    if not has_sector_size:
        # sfdisk -d may omit if 512; keep implicit but log
        pass
    for p in parts:
        f.write(p+"\n")

print(f"Wrote {tgt_dump} with {len(parts)} partitions, tgt_sectors {tgt_sectors}, sector {sector}")
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

# ---- per-partition clone helpers ----
# Fallback for dirty/hibernated NTFS: mkntfs + rsync -aHAX (as advertised in README)
ntfs_fallback_rsync() {
  local sdev="$1" tdev="$2" label="$3"
  warn "  ntfsclone failed — trying dirty fallback: mkntfs + rsync -aHAX"
  if ! command -v mkntfs >/dev/null 2>&1; then die "mkntfs not found (install ntfs-3g) for fallback"; fi
  if ! command -v rsync >/dev/null 2>&1; then die "rsync not found for dirty NTFS fallback (install rsync)"; fi
  if ! command -v mount >/dev/null 2>&1; then die "mount not found for fallback"; fi
  local mnt_src="$TMPDIR/mnt_src_$$" mnt_tgt="$TMPDIR/mnt_tgt_$$"
  mkdir -p "$mnt_src" "$mnt_tgt"
  # cleanup on return
  trap 'umount "$mnt_src" 2>/dev/null || true; umount "$mnt_tgt" 2>/dev/null || true; rmdir "$mnt_src" "$mnt_tgt" 2>/dev/null || true' RETURN
  info "  Creating fresh NTFS on $tdev (label=${label:-none})"
  if [[ -n "$label" ]]; then
    mkntfs -f -F -L "$label" "$tdev" 2>&1 | tee -a "$LOG_FILE" || die "mkntfs failed on $tdev"
  else
    mkntfs -f -F "$tdev" 2>&1 | tee -a "$LOG_FILE" || die "mkntfs failed on $tdev"
  fi
  partprobe "$TGT_REAL" 2>&1 | tee -a "$LOG_FILE" || true
  udevadm settle 2>&1 | tee -a "$LOG_FILE" || true
  sleep 1
  info "  Mounting source $sdev (ro) and target $tdev"
  # Source may be dirty/hibernated; try ro, then ro+remove_hiberfile, then ntfsfix
  if ! mount -t ntfs-3g -o ro "$sdev" "$mnt_src" 2>&1 | tee -a "$LOG_FILE"; then
    warn "  mount ro failed, trying remove_hiberfile"
    mount -t ntfs-3g -o ro,remove_hiberfile "$sdev" "$mnt_src" 2>&1 | tee -a "$LOG_FILE" || {
      warn "  trying ntfsfix to clear dirty flag"
      ntfsfix -d "$sdev" 2>&1 | tee -a "$LOG_FILE" || true
      mount -t ntfs-3g -o ro "$sdev" "$mnt_src" 2>&1 | tee -a "$LOG_FILE" || die "Failed to mount dirty source $sdev even after ntfsfix"
    }
  fi
  mount -t ntfs-3g "$tdev" "$mnt_tgt" 2>&1 | tee -a "$LOG_FILE" || die "Failed to mount fresh target $tdev"
  info "  rsync -aHAX $mnt_src/ -> $mnt_tgt/ (this may take a while)"
  rsync -aHAX --info=progress2 "$mnt_src"/ "$mnt_tgt"/ 2>&1 | tee -a "$LOG_FILE" || die "rsync failed $sdev -> $tdev"
  sync
  umount "$mnt_src" 2>&1 | tee -a "$LOG_FILE" || warn "umount src failed"
  umount "$mnt_tgt" 2>&1 | tee -a "$LOG_FILE" || warn "umount tgt failed"
  rmdir "$mnt_src" "$mnt_tgt" 2>/dev/null || true
  trap - RETURN 2>/dev/null || true
  ok "  Fallback rsync complete for $sdev -> $tdev"
}

info "Cloning partitions filesystem-aware..."
# Map partitions: source N -> target N (same order/count) — use mapfile to avoid IFS word-splitting pitfalls
SRC_PART_LIST=()
TGT_PART_LIST=()
mapfile -t SRC_PART_LIST < <(lsblk -n -r -o NAME "$SRC_REAL" | awk -v d="$(basename "$SRC_REAL")" '$1!=d')
mapfile -t TGT_PART_LIST < <(lsblk -n -r -o NAME "$TGT_REAL" | awk -v d="$(basename "$TGT_REAL")" '$1!=d')

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
  # BitLocker guard — ntfsclone cannot handle encrypted volumes
  if [[ "$fstype" == "BitLocker" ]] || blkid -o value -s TYPE "$sdev" 2>/dev/null | grep -qi "BitLocker"; then
    die "BitLocker detected on $sdev — decrypt/suspend BitLocker in Windows before cloning (manage-bde -off C:). Aborting."
  fi
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
        # Check if failure is due to BitLocker vs dirty
        if blkid -o value -s TYPE "$sdev" 2>/dev/null | grep -qi "BitLocker"; then
          die "ntfsclone failed due to BitLocker on $sdev — decrypt first"
        fi
        warn "ntfsclone failed on $sdev -> $tdev (likely dirty/hibernated NTFS)"
        # Try dirty fallback if available
        ntfs_fallback_rsync "$sdev" "$tdev" "$label"
      fi
      # If this is the main data partition (largest), resize to fill (only if ntfsclone path; fallback already sized)
      if [[ "$sdev" == "$MAIN_NTFS" ]]; then
        # Only resize if filesystem still smaller than partition (fallback mkntfs already fills)
        info "  Resizing main NTFS to fill partition (ntfsresize 100%)"
        ntfsresize --force --size 100% "$tdev" 2>&1 | tee -a "$LOG_FILE" || warn "ntfsresize failed - filesystem may still be smaller (fallback may have already filled)"
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
log "Log: $LOG_FILE (root copy: $LOG_FILE_ROOT)"
log "Next: Install $TGT_REAL in client PC and boot. If Windows shows 'Preparing Automatic Repair', boot WinPE USB and run: bcdboot C:\\Windows /s S: /f UEFI  (where S: is EFI partition)"
if [[ $DRY_RUN -eq 1 ]]; then ok "Dry-run finished - no data written"; fi

# trap handles cleanup; explicit rm for success path without relying on EXIT when sourced
rm -rf "${TMPDIR:-}" 2>/dev/null || true
trap - EXIT INT TERM 2>/dev/null || true
