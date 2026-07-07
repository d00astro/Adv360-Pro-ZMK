#!/usr/bin/env bash
#
# bin/flash.sh -- fetch CI-built firmware and interactively flash the
# Kinesis Advantage360 Pro (ZMK).
#
# Firmware is NOT built locally: the community-tested GitHub Actions artifact
# for this branch is downloaded via nightly.link (no token required), or a
# locally downloaded artifact zip can be passed as an argument.
#
# Usage: flash.sh [ZIPFILE] [--clique] [--branch BRANCH]
#                 [--left-only | --right-only] [--timeout SECONDS] [--fetch-only]
#
# Env overrides: FLASH_APPEAR_TIMEOUT, FLASH_DISAPPEAR_TIMEOUT (seconds)

set -euo pipefail

# --- configuration -----------------------------------------------------------

LABEL="ADV360PRO"
DEV_LINK="/dev/disk/by-label/${LABEL}"
POLL_INTERVAL=0.5
APPEAR_TIMEOUT="${FLASH_APPEAR_TIMEOUT:-300}"
DISAPPEAR_TIMEOUT="${FLASH_DISAPPEAR_TIMEOUT:-120}"

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FIRMWARE_DIR="${REPO_ROOT}/firmware"
DEFAULT_SLUG="d00astro/Adv360-Pro-ZMK"
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
Usage: flash.sh [ZIPFILE] [OPTIONS]

Fetch the CI-built Advantage360 Pro firmware (the GitHub Actions artifact,
via nightly.link -- no token needed) and interactively flash both halves.
With ZIPFILE, use a locally downloaded artifact zip instead of downloading.

Options:
  --clique           fetch the ZMK Studio build (artifact 'firmware-clique');
                     default is 'firmware-no-clique'
  --branch BRANCH    fetch the artifact for this branch (default: current git
                     branch, falling back to 'engrammer')
  --left-only        flash only the left half
  --right-only       flash only the right half
  --fetch-only       download, verify, copy to firmware/ -- do not flash
  --timeout SECONDS  how long to wait for the bootloader drive (default ${APPEAR_TIMEOUT})
  -h, --help         show this help
EOF
}

# --- cleanup -----------------------------------------------------------------

MOUNT_DIR=""     # where the bootloader volume is mounted (ours or pre-existing)
TMP_MOUNT=""     # temp dir we created via mktemp (needs rmdir)
MOUNTED_BY_US=0  # 1 when we ran the mount and must umount
TMP_DL=""        # download/extract scratch dir

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
  if [[ -n "$TMP_DL" && -d "$TMP_DL" ]]; then
    rm -rf -- "$TMP_DL"
    TMP_DL=""
  fi
}
trap cleanup EXIT
trap 'printf "\n"; warn "aborted by user"; exit 130' INT TERM

# --- device helpers ------------------------------------------------------------

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
      warn "still waiting (30s). Are the LEDs solid green? If not, DOUBLE-CLICK"
      warn "the physical reset button (center of the thumb cluster) -- this works"
      warn "even when the firmware is dead. Also make sure the USB cable carries data."
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
  2. Enter bootloader mode -- either method works:
       ${BOLD}reset button:${RESET} DOUBLE-CLICK the small reset button in the center
         of the thumb cluster. ${BOLD}Use this one if the keyboard does not respond
         to keypresses${RESET} -- broken firmware cannot process the key combo.
       ${BOLD}key combo:${RESET}    ${BOLD}${combo}${RESET} (needs working firmware)
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

# --- per-half flow --------------------------------------------------------------

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
    || die "the ${LABEL} drive never disappeared -- the ${side} flash may not have completed; unplug it, then rerun with --${side}-only (pass the same ZIPFILE if you used one)"

  ok "${side^^} half flashed: $(basename -- "$uf2")"
}

# --- artifact acquisition ------------------------------------------------------

# owner/repo from the origin remote; hardcoded fallback.
repo_slug() {
  local url slug
  url="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
  slug="${url#*github.com[:/]}"
  slug="${slug%.git}"
  if [[ "$url" == *github.com* && "$slug" =~ ^[^/]+/[^/]+$ ]]; then
    printf '%s\n' "$slug"
  else
    printf '%s\n' "$DEFAULT_SLUG"
  fi
}

download_artifact() {   # sets ZIP_PATH
  local url="https://nightly.link/${SLUG}/workflows/build/${BRANCH}/${ARTIFACT}.zip"
  info "downloading ${ARTIFACT} for branch '${BRANCH}'"
  info "  ${url}"
  if ! curl -fL --retry 2 --connect-timeout 15 -o "${TMP_DL}/${ARTIFACT}.zip" "$url"; then
    die "download failed.
   - no completed CI run for branch '${BRANCH}'? check https://github.com/${SLUG}/actions
   - nightly.link may be down: download the artifact zip from the Actions run
     page in a browser and pass it directly:  flash /path/to/${ARTIFACT}.zip"
  fi
  ZIP_PATH="${TMP_DL}/${ARTIFACT}.zip"
}

extract_zip() {         # sets EXTRACT_DIR
  EXTRACT_DIR="${TMP_DL}/extract"
  mkdir -p "$EXTRACT_DIR"
  if ! unzip -q -o "$ZIP_PATH" -d "$EXTRACT_DIR"; then
    die "could not extract ${ZIP_PATH} -- not a zip archive?
   (a proxy or captive portal may have served an HTML error page instead of
    the artifact; download it manually from https://github.com/${SLUG}/actions)"
  fi
}

# Find the .uf2 for one side. CI artifacts: <timestamp>-<sha7>-<side>.uf2;
# stock Kinesis zips: <side>.uf2. Searches nested directories too.
locate_uf2() {          # $1 = left|right; prints the chosen path
  local side="$1" candidates=()
  mapfile -t candidates < <(
    find "$EXTRACT_DIR" -type f \( -iname "*-${side}.uf2" -o -iname "${side}.uf2" \) | sort
  )
  if (( ${#candidates[@]} == 0 )); then
    warn "archive contents:"
    unzip -l "$ZIP_PATH" >&2
    die "no ${side} firmware (*-${side}.uf2 or ${side}.uf2) in the archive"
  fi
  if (( ${#candidates[@]} > 1 )); then
    warn "multiple ${side} images in the archive:"
    printf '     %s\n' "${candidates[@]}" >&2
    warn "picking the lexicographically newest"
    confirm "Continue with $(basename -- "${candidates[-1]}")?" \
      || die "aborted -- pass a zip containing a single ${side} image"
  fi
  printf '%s\n' "${candidates[-1]}"
}

check_uf2_image() {     # $1 = path, $2 = side
  local f="$1" side="$2" magic size mtime
  magic="$(head -c 4 -- "$f" | od -An -tx1 | tr -d ' \n')"
  [[ "$magic" == "5546320a" ]] \
    || die "${side} image $(basename -- "$f") is not a UF2 file (bad magic)"
  size="$(stat -c '%s' -- "$f")"
  if (( size == 0 || size % 512 != 0 )); then
    warn "${side} image size (${size} B) is not a multiple of 512 -- unusual for UF2"
  fi
  mtime="$(stat -c '%y' -- "$f" | cut -d'.' -f1)"
  info "${side} firmware: $(basename -- "$f") ($(numfmt --to=iec-i --suffix=B "$size"), ${mtime})"
}

# Compare the 7-char sha embedded in CI filenames against local HEAD.
check_provenance() {    # args: uf2 paths
  local head_sha sha="" s base f shas=()
  head_sha="$(git -C "$REPO_ROOT" rev-parse --short=7 HEAD 2>/dev/null || true)"
  for f in "$@"; do
    base="$(basename -- "$f")"
    if [[ "$base" =~ ^[0-9]{12}-([0-9a-f]{7})- ]]; then
      shas+=("${BASH_REMATCH[1]}")
    fi
  done
  if (( ${#shas[@]} == 0 )); then
    info "no commit hash in the firmware filenames (stock/manual zip?) -- skipping provenance check"
    return 0
  fi
  sha="${shas[0]}"
  for s in "${shas[@]}"; do
    [[ "$s" == "$sha" ]] || warn "left/right images come from DIFFERENT commits: ${shas[*]}"
  done
  if [[ -n "$head_sha" && "$sha" != "$head_sha" ]]; then
    warn "artifact was built from commit ${sha}, but local HEAD is ${head_sha}"
    warn "if you just pushed, CI has probably not finished yet -- nightly.link"
    warn "serves the latest COMPLETED run: https://github.com/${SLUG}/actions"
    if (( ! FETCH_ONLY )); then
      confirm "Flash the ${sha} firmware anyway?" || die "aborted -- wait for CI to finish, then rerun"
    fi
  elif [[ -n "$head_sha" ]]; then
    ok "artifact matches local HEAD (${head_sha})"
  fi
  if [[ -n "$(git -C "$REPO_ROOT" status --porcelain -- config 2>/dev/null)" ]]; then
    warn "config/ has uncommitted local changes -- they are in NO CI artifact"
  fi
}

# --- argument parsing ----------------------------------------------------------

ZIPFILE=""
ARTIFACT="firmware-no-clique"
BRANCH=""
FETCH_ONLY=0
DO_LEFT=1
DO_RIGHT=1
while (( $# > 0 )); do
  case "$1" in
    --clique)     ARTIFACT="firmware-clique" ;;
    --branch)     shift; BRANCH="${1:?--branch requires a branch name}" ;;
    --left-only)  DO_RIGHT=0 ;;
    --right-only) DO_LEFT=0 ;;
    --fetch-only) FETCH_ONLY=1 ;;
    --timeout)    shift; APPEAR_TIMEOUT="${1:?--timeout requires a value in seconds}" ;;
    -h|--help)    usage; exit 0 ;;
    -*)           die "unknown option: $1 (try --help)" ;;
    *)            [[ -z "$ZIPFILE" ]] || die "unexpected extra argument: $1"
                  ZIPFILE="$1" ;;
  esac
  shift
done
(( DO_LEFT || DO_RIGHT )) || die "--left-only and --right-only are mutually exclusive"
if [[ -n "$ZIPFILE" ]]; then
  [[ -f "$ZIPFILE" ]] || die "no such file: ${ZIPFILE}"
  [[ -z "$BRANCH" ]] || warn "--branch is ignored when a local ZIPFILE is given"
  [[ "$ARTIFACT" == "firmware-no-clique" ]] || warn "--clique is ignored when a local ZIPFILE is given"
fi

# --- dependency checks -----------------------------------------------------------

require_cmd() {
  command -v "$1" >/dev/null 2>&1 \
    || die "'$1' not found -- run inside the devenv shell ('devenv shell', or 'direnv allow' once)"
}
require_cmd unzip
require_cmd od
require_cmd numfmt
[[ -n "$ZIPFILE" ]] || require_cmd curl
(( FETCH_ONLY )) || require_cmd findmnt

# --- main -------------------------------------------------------------------------

SLUG="$(repo_slug)"
if [[ -z "$BRANCH" ]]; then
  BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  [[ -n "$BRANCH" && "$BRANCH" != "HEAD" ]] || BRANCH="engrammer"
fi

TMP_DL="$(mktemp -d /tmp/adv360-fetch.XXXXXX)"

if [[ -n "$ZIPFILE" ]]; then
  ZIP_PATH="$ZIPFILE"
  info "using local artifact: ${ZIPFILE}"
else
  download_artifact
fi
extract_zip

LEFT_UF2=""
RIGHT_UF2=""
if (( DO_LEFT ));  then LEFT_UF2="$(locate_uf2 left)";   fi
if (( DO_RIGHT )); then RIGHT_UF2="$(locate_uf2 right)"; fi

# Keep copies in firmware/ (gitignored) so the images survive temp-dir cleanup
# and there is a record of what was flashed.
mkdir -p "$FIRMWARE_DIR"
if [[ -n "$LEFT_UF2" ]]; then
  cp -- "$LEFT_UF2" "$FIRMWARE_DIR/"
  LEFT_UF2="${FIRMWARE_DIR}/$(basename -- "$LEFT_UF2")"
fi
if [[ -n "$RIGHT_UF2" ]]; then
  cp -- "$RIGHT_UF2" "$FIRMWARE_DIR/"
  RIGHT_UF2="${FIRMWARE_DIR}/$(basename -- "$RIGHT_UF2")"
fi

if [[ -n "$LEFT_UF2" ]];  then check_uf2_image "$LEFT_UF2"  "left";  fi
if [[ -n "$RIGHT_UF2" ]]; then check_uf2_image "$RIGHT_UF2" "right"; fi
check_provenance ${LEFT_UF2:+"$LEFT_UF2"} ${RIGHT_UF2:+"$RIGHT_UF2"}

if (( FETCH_ONLY )); then
  ok "firmware fetched and verified (not flashing):"
  [[ -z "$LEFT_UF2"  ]] || printf '     %s\n' "$LEFT_UF2"
  [[ -z "$RIGHT_UF2" ]] || printf '     %s\n' "$RIGHT_UF2"
  exit 0
fi

info "sudo is needed once to mount the bootloader drive; caching credentials now"
sudo -v

if (( DO_LEFT ));  then flash_half "left"  "$LEFT_UF2"  "$LEFT_COMBO";  fi
if (( DO_RIGHT )); then flash_half "right" "$RIGHT_UF2" "$RIGHT_COMBO"; fi

printf '\n%s\n' "${GREEN}${BOLD}All done.${RESET}"
info "repo convention -- tag this flash:"
printf '      git tag flashed-%s && git push origin --tags\n' "$(date +%Y%m%d)"
