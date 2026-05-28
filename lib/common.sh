# shellcheck shell=bash

require_command() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: required command not found: ${cmd}" >&2
    exit 1
  fi
}

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "ERROR: required variable is not set: ${name}" >&2
    exit 1
  fi
}

require_positive_int() {
  local name="$1"
  local value="${!name:-}"

  if ! [[ "${value}" =~ ^[0-9]+$ ]] || (( value <= 0 )); then
    echo "ERROR: ${name} must be a positive integer, got: ${value:-<unset>}" >&2
    exit 1
  fi
}

# Proxmox reserves VMIDs 0-99 for internal use; user VMs must be >= 100.
require_vmid() {
  local name="$1"
  local value="${!name:-}"

  if ! [[ "${value}" =~ ^[0-9]+$ ]] || (( value < 100 )); then
    echo "ERROR: ${name} must be an integer >= 100 (Proxmox reserves 0-99), got: ${value:-<unset>}" >&2
    exit 1
  fi
}

require_bool() {
  local name="$1"
  local value="${!name:-}"

  if [[ "${value}" != "0" && "${value}" != "1" ]]; then
    echo "ERROR: ${name} must be 0 or 1, got: ${value:-<unset>}" >&2
    exit 1
  fi
}

storage_exists() {
  local storage="$1"
  local output
  if ! output="$(pvesm status 2>&1)"; then
    echo "ERROR: 'pvesm status' failed: ${output}" >&2
    return 1
  fi
  printf '%s\n' "${output}" | awk 'NR > 1 {print $1}' | grep -qx "${storage}"
}

bridge_exists() {
  local bridge="$1"
  ip link show "${bridge}" >/dev/null 2>&1
}

vm_exists() {
  local vmid="$1"
  qm status "${vmid}" >/dev/null 2>&1
}

vm_is_running() {
  local vmid="$1"
  local status
  status="$(qm status "${vmid}" 2>/dev/null || true)"
  [[ "${status}" == "status: running" ]]
}

require_proxmox_host_tools() {
  require_command qm
  require_command pvesm
  require_command awk
  require_command grep
  require_command ip
}
