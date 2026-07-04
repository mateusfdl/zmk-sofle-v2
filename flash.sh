#!/usr/bin/env bash
set -euo pipefail

readonly REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly FIRMWARE_DIR="${REPO_DIR}/.firmware"
readonly WORKFLOW="Build ZMK firmware"
readonly ARTIFACT="firmware"
readonly BUILD_LIMIT=10
readonly REBOOT_TIMEOUT=30

readonly RESET_UF2="eyelash_sofle_settings_reset.uf2"
readonly LEFT_UF2="eyelash_sofle_studio_left.uf2"
readonly RIGHT_UF2="eyelash_sofle_right.uf2"
readonly REQUIRED_FILES=("${RESET_UF2}" "${LEFT_UF2}" "${RIGHT_UF2}")

firmware_dir=""

log() {
  printf '%s\n' "$*" >&2
}

die() {
  log "error: $*"
  exit 1
}

require_commands() {
  local command_name

  for command_name in gh udisksctl lsblk awk; do
    command -v "${command_name}" >/dev/null || die "${command_name} is required"
  done
}

run_dir() {
  printf '%s/%s\n' "${FIRMWARE_DIR}" "$1"
}

has_firmware_files() {
  local dir="$1"
  local file_name

  for file_name in "${REQUIRED_FILES[@]}"; do
    [[ -f "${dir}/${file_name}" ]] || return 1
  done
}

require_firmware_files() {
  local run_id="$1"
  local dir="$2"
  local file_name

  for file_name in "${REQUIRED_FILES[@]}"; do
    [[ -f "${dir}/${file_name}" ]] || die "artifact of run ${run_id} is missing ${file_name}"
  done
}

download_build() {
  local run_id="$1"
  local dir
  dir="$(run_dir "${run_id}")"

  if ! has_firmware_files "${dir}"; then
    rm -rf -- "${dir}"
    mkdir -p -- "${dir}"
    log "downloading firmware artifact for run ${run_id}..."
    gh run download "${run_id}" -n "${ARTIFACT}" -D "${dir}"
    require_firmware_files "${run_id}" "${dir}"
  fi

  firmware_dir="${dir}"
}

read_choice() {
  local prompt="$1"
  local max="$2"
  local choice

  while true; do
    read -rp "${prompt}" choice
    [[ "${choice}" =~ ^[0-9]+$ && "${choice}" -ge 1 && "${choice}" -le "${max}" ]] && break
    log "invalid choice"
  done

  printf '%s\n' "${choice}"
}

select_build() {
  local -a builds
  mapfile -t builds < <(
    gh run list \
      --workflow "${WORKFLOW}" \
      --status success \
      --json databaseId,headSha,displayTitle,createdAt \
      --limit "${BUILD_LIMIT}" \
      --jq '.[] | "\(.databaseId)\t\(.headSha[:7])\t\(.createdAt[2:10])\t\(.displayTitle)"'
  )

  ((${#builds[@]} > 0)) || die "no successful '${WORKFLOW}' runs found"

  local index run_id sha created title

  log ""
  log "available firmware builds:"
  for index in "${!builds[@]}"; do
    IFS=$'\t' read -r run_id sha created title <<<"${builds[${index}]}"
    log "  $((index + 1))) ${title} (${sha}) - ${created}"
  done

  local choice
  choice="$(read_choice "select a build [1-${#builds[@]}]: " "${#builds[@]}")"
  IFS=$'\t' read -r run_id sha created title <<<"${builds[$((choice - 1))]}"

  download_build "${run_id}"
  log "using build: ${title} (${sha}) - ${created}"
}

mountpoint_for() {
  lsblk -rno MOUNTPOINT "/dev/$1" 2>/dev/null | head -1
}

find_uf2_mount() {
  local device mountpoint

  while IFS= read -r device; do
    mountpoint="$(mountpoint_for "${device}")"

    if [[ -z "${mountpoint}" ]]; then
      udisksctl mount -b "/dev/${device}" >/dev/null 2>&1 || continue
      mountpoint="$(mountpoint_for "${device}")"
    fi

    [[ -n "${mountpoint}" && -f "${mountpoint}/INFO_UF2.TXT" ]] || continue
    printf '%s\n' "${mountpoint}"
    return
  done < <(lsblk -rno NAME,RM,FSTYPE | awk '$2 == "1" && $3 == "vfat" { print $1 }')

  return 1
}

wait_for_bootloader() {
  local mountpoint

  log "waiting for bootloader (double-tap the reset button)..."
  until mountpoint="$(find_uf2_mount)"; do
    sleep 1
  done

  printf '%s\n' "${mountpoint}"
}

wait_for_reboot() {
  local mountpoint="$1"
  local elapsed=0

  while [[ -d "${mountpoint}" && -f "${mountpoint}/INFO_UF2.TXT" ]]; do
    ((elapsed >= REBOOT_TIMEOUT)) && die "device did not reboot after flashing, check the keyboard"
    sleep 1
    ((elapsed += 1))
  done
}

flash_file() {
  local file_path="$1"
  local mountpoint
  mountpoint="$(wait_for_bootloader)"

  log "flashing $(basename "${file_path}") -> ${mountpoint}"
  cp -- "${file_path}" "${mountpoint}/" 2>/dev/null || true
  sync 2>/dev/null || true
  wait_for_reboot "${mountpoint}"
  log "flashed $(basename "${file_path}")"
}

flash_side() {
  local side_uf2="$1"

  flash_file "${firmware_dir}/${RESET_UF2}"
  log "settings reset applied"
  flash_file "${firmware_dir}/${side_uf2}"
  log "side flashed successfully"
}

main() {
  cd "${REPO_DIR}"
  require_commands
  select_build

  local choice
  while true; do
    log ""
    log "what do you want to flash?"
    log "  1) left  (${LEFT_UF2})"
    log "  2) right (${RIGHT_UF2})"
    log "  3) pick another build"
    log "  4) quit"

    choice="$(read_choice "choice [1-4]: " 4)"
    case "${choice}" in
      1) flash_side "${LEFT_UF2}" ;;
      2) flash_side "${RIGHT_UF2}" ;;
      3) select_build ;;
      4) exit 0 ;;
    esac
  done
}

main "$@"
