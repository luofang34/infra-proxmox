#!/usr/bin/env bash
# Variables marked as "possibly unassigned" come from the user-supplied env
# file sourced below; shellcheck cannot see through that.
# shellcheck disable=SC2153
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

if [[ $# -ne 1 ]]; then
  echo "usage: $0 path/to/vm.env" >&2
  exit 2
fi

VM_ENV="$1"
if [[ ! -f "${VM_ENV}" ]]; then
  echo "ERROR: env file not found: ${VM_ENV}" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${VM_ENV}"

require_command qm
require_command pvesm
require_command grep

require_var VMID
require_var NAME
require_var LOCAL_DISK_STORAGE
require_var NFS_STORAGE

require_vmid VMID

SHUTDOWN_TIMEOUT_S="${SHUTDOWN_TIMEOUT_S:-60}"
require_positive_int SHUTDOWN_TIMEOUT_S

if ! vm_exists "${VMID}"; then
  echo "ERROR: VMID ${VMID} does not exist on this host; nothing to destroy." >&2
  exit 1
fi

cat <<EOF
About to destroy Proxmox VM:

  VMID:          ${VMID}
  Name:          ${NAME}
  Local storage: ${LOCAL_DISK_STORAGE}
  NFS storage:   ${NFS_STORAGE}

This will remove the VM configuration and attempt to remove associated disks.

EOF

expected_token="destroy ${VMID}"
DESTROY_TOKEN="${DESTROY_TOKEN:-}"
if [[ "${DESTROY_TOKEN}" != "${expected_token}" ]]; then
  read -r -p "Destroy this VM? Type '${expected_token}' to continue: " answer
  if [[ "${answer}" != "${expected_token}" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

if vm_is_running "${VMID}"; then
  echo "VM ${VMID} is running; requesting graceful shutdown (timeout ${SHUTDOWN_TIMEOUT_S}s, will force on timeout)..."
  if ! qm shutdown "${VMID}" --timeout "${SHUTDOWN_TIMEOUT_S}" --forceStop 1; then
    echo "WARNING: qm shutdown returned non-zero; attempting hard stop." >&2
    qm stop "${VMID}"
  fi
fi

echo "Destroying VM ${VMID}..."
qm destroy "${VMID}" --purge --destroy-unreferenced-disks 1

echo
echo "Checking for leftover volumes:"
leftover_local="$(pvesm list "${LOCAL_DISK_STORAGE}" | grep "vm-${VMID}" || true)"
leftover_nfs="$(pvesm list "${NFS_STORAGE}" | grep "vm-${VMID}" || true)"

if [[ -n "${leftover_local}" ]]; then
  echo "Leftover on ${LOCAL_DISK_STORAGE}:"
  printf '%s\n' "${leftover_local}"
fi

if [[ -n "${leftover_nfs}" ]]; then
  echo "Leftover on ${NFS_STORAGE}:"
  printf '%s\n' "${leftover_nfs}"
fi

if [[ -z "${leftover_local}" && -z "${leftover_nfs}" ]]; then
  echo "No leftover volumes found."
fi
