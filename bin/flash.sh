#!/usr/bin/env bash
#
# bin/flash.sh -- interactive UF2 flasher for the Kinesis Advantage360 Pro (ZMK).
#
# Flow: build both halves (unless --no-build), then for LEFT and RIGHT in turn:
#   1. prompt the user to plug that half in directly via USB and enter
#      bootloader mode (LEDs solid green)
#   2. poll for /dev/disk/by-label/ADV360PRO
#   3. mount it (or reuse an existing mountpoint), verify INFO_UF2.TXT,
#      copy the freshly built .uf2, sync, unmount
#   4. treat device disappearance after the copy as SUCCESS (UF2 auto-eject)
#   5. require the drive to disappear before the other half may start
#
# Usage: flash.sh [--no-build] [--left-only | --right-only] [--timeout SECONDS]
#
# Env overrides: FLASH_BUILD_CMD (default: build)
#                FLASH_APPEAR_TIMEOUT, FLASH_DISAPPEAR_TIMEOUT (seconds)

set -euo pipefail

# --- configuration -----------------------------------------------------------

LABEL="ADV360PRO"
DEV_LINK="/dev/disk/by-label/${LABEL}"
POLL_INTERVAL=0.5
APPEAR_TIMEOUT="${FLASH_APPEAR_TIMEOUT:-300}"
DISAPPEAR_TIMEOUT="${FLASH_DISAPPEAR_TIMEOUT:-120}"
BUILD_CMD="${FLASH_BUILD_CMD:-build}"

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LEFT_UF2="${REPO_ROOT}/build/left/zephyr/zmk.uf2"
RIGHT_UF2="${REPO_ROOT}/build/right/zephyr/zmk.uf2"
LEFT_COMBO="Mod + Hotkey 1"
RIGHT_COMBO="Mod + Hotkey 3"

# --- output helpers ----------------------------------------------------------

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  BOLD=$'\e[1m'; RED=$'\e[31m'; GREEN=$'\e[32m'
  YELLOW=$'\e[33m'; BLUE=$'\e[34m'; RESET=$'\e[0m'
else
  BOLD=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi

info() { printf '%s\n' "${BLUE}::${RESET} $*"; }
ok()   { printf '%s\n' "${GREEN}ok${RESET} $*"; }
warn() { printf '%s\n' "${YELLOW}!!${RESET} $*" >&2; }
die()  { printf '%s\n' "${RED}error:${RESET} $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: flash.sh [OPTIONS]

Build the Advantage360 Pro firmware and interactively flash both halves.

Options:
  --no-build         skip the build; flash existing build/*/zephyr/zmk.uf2
  --left-only        flash only the left half
  --right-only       flash only the right half
  --timeout SECONDS  how long to wait for the bootloader drive (default ${APPEAR_TIMEOUT})
  -h, --help         show this help
EOF
}

# --- cleanup -----------------------------------------------------------------

MOUNT_DIR=""     # where the bootloader volume is mounted (ours or pre-existing)
TMP_MOUNT=""     # temp dir we created via mktemp (needs rmdir)
MOUNTED_BY_US=0  # 1 when we ran the mount and must umount

cleanup() {
  if [[ "$MOUNTED_BY_US" -eq 1 && -n "$MOUNT_DIR" ]]; then
    sudo umount "$MOUNT_DIR" 2>/dev/null \
      || sudo umount -l "$MOUNT_DIR" 2>/dev/null || true
    MOUNTED_BY_US=0
  fi
  if [[ -n "$TMP_MOUNT" && -d "$TMP_MOUNT" ]]; then
    rmdir "$TMP_MOUNT" 2>/dev/null || true
    TMP_MOUNT=""
  fi
}
trap cleanup EXIT
trap 'printf "\n"; warn "aborted by user"; exit 130' INT TERM

# --- device helpers ----------------------------------------------------------

device_present() { [[ -e "$DEV_LINK" ]]; }

confirm() {
  local reply
  read -rp "$1 [y/N] " reply
  [[ "$reply" == [yY]* ]]
}

# Poll until the bootloader drive appears. Returns 1 on timeout.
wait_for_device() {
  local ticks=0
  local max=$(( APPEAR_TIMEOUT * 2 ))     # 0.5s per tick
  printf '   waiting for %s ' "$DEV_LINK"
  while ! device_present; do
    if (( ticks >= max )); then
      printf '\n'
      warn "timed out after ${APPEAR_TIMEOUT}s waiting for the bootloader drive"
      warn "run 'lsblk -o NAME,LABEL,SIZE,MOUNTPOINTS' in another terminal to see"
      warn "whether the device shows up at all (it may enumerate without the label)"
      return 1
    fi
    if (( ticks == 60 )); then           # 30s in
      printf '\n'
      warn "still waiting (30s). Are the LEDs solid green? If not, retry the"
      warn "bootloader combo, or double-click the reset button (center of the"
      warn "thumb cluster). Also make sure the USB cable carries data."
      printf '   waiting '
    fi
    sleep "$POLL_INTERVAL"
    if (( ticks % 2 == 0 )); then printf '.'; fi
    ticks=$(( ticks + 1 ))
  done
  printf ' %sfound%s\n' "$GREEN" "$RESET"
}

# Poll until the bootloader drive disappears. Returns 1 on timeout.
wait_for_device_gone() {
  local ticks=0
  local max=$(( DISAPPEAR_TIMEOUT * 2 ))
  printf '   waiting for the drive to disappear '
  while device_present; do
    if (( ticks >= max )); then
      printf '\n'
      return 1
    fi
    if (( ticks == 20 )); then           # 10s in
      printf '\n'
      warn "the drive is still visible; if the keyboard did not reboot on its"
      warn "own, unplug the USB cable now"
      printf '   waiting '
    fi
    sleep "$POLL_INTERVAL"
    if (( ticks % 2 == 0 )); then printf '.'; fi
    ticks=$(( ticks + 1 ))
  done
  printf ' %sgone%s\n' "$GREEN" "$RESET"
}

prompt_bootloader() {
  local side="$1" combo="$2"
  cat <<EOF

  1. Plug the ${BOLD}${side^^}${RESET} half DIRECTLY into this computer via USB
     (not through the other half, not over Bluetooth).
  2. Enter bootloader mode: press ${BOLD}${combo}${RESET}
     (fallback: double-click the reset button in the center of the thumb cluster).
  3. The LEDs turn ${GREEN}solid green${RESET} when the bootloader is active.

EOF
  read -rp "Press Enter when ready (Ctrl-C to abort)... "
}

# Mount the bootloader volume, or adopt an existing mountpoint.
# Sets MOUNT_DIR, TMP_MOUNT, MOUNTED_BY_US.
mount_device() {
  local dev existing opts
  dev="$(readlink -f -- "$DEV_LINK")"
  existing="$(findmnt -n -o TARGET --source "$dev" 2>/dev/null | head -n1 || true)"
  if [[ -n "$existing" ]]; then
    opts="$(findmnt -n -o OPTIONS --source "$dev" 2>/dev/null | head -n1 || true)"
    if [[ ",${opts}," == *",ro,"* ]]; then
      die "device is mounted read-only at ${existing}; remount it read-write or unmount it and rerun"
    fi
    if [[ ! -w "$existing" ]]; then
      die "device is mounted at ${existing} but not writable by $(id -un); unmount it and rerun so this script can mount it with uid=$(id -u)"
    fi
    info "device already mounted at ${existing} -- using it"
    MOUNT_DIR="$existing"
    MOUNTED_BY_US=0
  else
    TMP_MOUNT="$(mktemp -d /tmp/adv360-flash.XXXXXX)"
    sudo -v   # silent while the timestamp cache from startup is still valid
    sudo mount -t vfat -o "uid=$(id -u),gid=$(id -g),flush" "$dev" "$TMP_MOUNT"
    MOUNT_DIR="$TMP_MOUNT"
    MOUNTED_BY_US=1
    info "mounted ${dev} at ${MOUNT_DIR}"
  fi
}

verify_uf2_volume() {
  local marker
  marker="$(find "$MOUNT_DIR" -maxdepth 1 -iname 'INFO_UF2.TXT' -print -quit 2>/dev/null || true)"
  if [[ -z "$marker" ]]; then
    warn "no INFO_UF2.TXT on the mounted volume -- this is NOT a UF2 bootloader drive"
    die "refusing to copy; unplug/unmount the device labelled ${LABEL} and check it"
  fi
}

# Copy the .uf2. The UF2 bootloader auto-installs and reboots once the image is
# fully written, so the drive may vanish mid-cp or mid-sync -- that is success.
copy_uf2() {
  local uf2="$1" side="$2"
  info "copying $(basename -- "$uf2") -> ${MOUNT_DIR}/"
  if ! cp -- "$uf2" "${MOUNT_DIR}/"; then
    sleep 2
    if device_present; then
      die "copying the ${side} firmware failed and the device is still attached (I/O error, no space, or an unwritable manual mount?)"
    fi
    warn "cp reported an error but the drive has disappeared -- this is the"
    warn "normal UF2 auto-eject; treating the ${side} flash as successful"
    return 0
  fi
  if ! sync -f "$MOUNT_DIR" 2>/dev/null; then
    sleep 2
    if device_present; then
      die "sync failed while the device is still attached -- the ${side} flash may be incomplete"
    fi
    warn "drive disappeared during sync -- normal UF2 auto-eject; ${side} flash successful"
  fi
}

# Release our mount (best-effort: the device usually ejects itself first).
release_device() {
  if [[ "$MOUNTED_BY_US" -eq 1 ]]; then
    sudo umount "$MOUNT_DIR" 2>/dev/null \
      || sudo umount -l "$MOUNT_DIR" 2>/dev/null || true
    MOUNTED_BY_US=0
  fi
  if [[ -n "$TMP_MOUNT" ]]; then
    rmdir "$TMP_MOUNT" 2>/dev/null || true
    TMP_MOUNT=""
  fi
  MOUNT_DIR=""
}

# --- per-half flow -----------------------------------------------------------

flash_half() {
  local side="$1" uf2="$2" combo="$3"

  printf '\n%s\n' "${BOLD}=== ${side^^} half ===${RESET}"

  if device_present; then
    warn "a ${LABEL} bootloader drive is ALREADY attached"
    if [[ "$side" == "right" ]]; then
      warn "${BOLD}make sure it is the RIGHT half${RESET} -- if the LEFT half is still"
      warn "plugged in, it would receive the right-half firmware!"
    fi
    if ! confirm "Is the attached device the ${side^^} half in bootloader mode?"; then
      info "unplug it now"
      wait_for_device_gone \
        || die "the ${LABEL} drive is still attached; unplug it and rerun"
      prompt_bootloader "$side" "$combo"
      wait_for_device || die "no bootloader drive appeared for the ${side} half"
    fi
  else
    prompt_bootloader "$side" "$combo"
    wait_for_device || die "no bootloader drive appeared for the ${side} half"
  fi

  sleep 1   # let udev/kernel settle before mounting
  mount_device
  verify_uf2_volume
  copy_uf2 "$uf2" "$side"
  release_device

  # CRITICAL: the drive must vanish before the other half may be flashed,
  # otherwise the next .uf2 could land on this same (still-attached) half.
  wait_for_device_gone \
    || die "the ${LABEL} drive never disappeared -- the ${side} flash may not have completed; unplug it, then rerun with --${side}-only --no-build"

  ok "${side^^} half flashed: $(basename -- "$uf2")"
}

check_artifact() {
  local uf2="$1" side="$2" size mtime age
  [[ -f "$uf2" ]] \
    || die "missing ${side} firmware: ${uf2} (run without --no-build, or run '${BUILD_CMD}' first)"
  size="$(numfmt --to=iec-i --suffix=B "$(stat -c '%s' -- "$uf2")")"
  mtime="$(stat -c '%y' -- "$uf2" | cut -d'.' -f1)"
  info "${side} firmware: ${uf2} (${size}, built ${mtime})"
  if (( DO_BUILD == 0 )); then
    age=$(( $(date +%s) - $(stat -c '%Y' -- "$uf2") ))
    if (( age > 3600 )); then
      warn "${side} firmware is $(( age / 3600 ))h old -- is this the build you meant to flash?"
    fi
  fi
}

# --- argument parsing --------------------------------------------------------

DO_BUILD=1
DO_LEFT=1
DO_RIGHT=1
while (( $# > 0 )); do
  case "$1" in
    --no-build)   DO_BUILD=0 ;;
    --left-only)  DO_RIGHT=0 ;;
    --right-only) DO_LEFT=0 ;;
    --timeout)    shift; APPEAR_TIMEOUT="${1:?--timeout requires a value in seconds}" ;;
    -h|--help)    usage; exit 0 ;;
    *)            die "unknown option: $1 (try --help)" ;;
  esac
  shift
done
(( DO_LEFT || DO_RIGHT )) || die "--left-only and --right-only are mutually exclusive"

# --- main --------------------------------------------------------------------

if (( DO_BUILD )); then
  command -v "$BUILD_CMD" >/dev/null 2>&1 \
    || die "build command '${BUILD_CMD}' not found -- run inside the devenv shell, set FLASH_BUILD_CMD, or pass --no-build"
  info "building firmware ('${BUILD_CMD}')..."
  "$BUILD_CMD"
  ok "build finished"
fi

if (( DO_LEFT ));  then check_artifact "$LEFT_UF2"  "left";  fi
if (( DO_RIGHT )); then check_artifact "$RIGHT_UF2" "right"; fi

info "sudo is needed once to mount the bootloader drive; caching credentials now"
sudo -v

if (( DO_LEFT ));  then flash_half "left"  "$LEFT_UF2"  "$LEFT_COMBO";  fi
if (( DO_RIGHT )); then flash_half "right" "$RIGHT_UF2" "$RIGHT_COMBO"; fi

printf '\n%s\n' "${GREEN}${BOLD}All done.${RESET}"
info "repo convention -- tag this flash:"
printf '      git tag flashed-%s && git push origin --tags\n' "$(date +%Y%m%d)"
