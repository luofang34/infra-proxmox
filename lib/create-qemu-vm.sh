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

require_proxmox_host_tools

# Required identity / placement.
require_var VMID
require_var NAME
require_var ISO_STORAGE
require_var ISO_FILE
require_var BRIDGE
require_var LOCAL_DISK_STORAGE
require_var NFS_STORAGE

# Required sizing.
require_var CORES
require_var MEMORY_MB
require_var BALLOON_MB
require_var CPUUNITS
require_var SYSTEM_DISK_GB
require_var NIX_DISK_GB
require_var WORK_DISK_GB

# Optional with defaults.
SOCKETS="${SOCKETS:-1}"
ONBOOT="${ONBOOT:-0}"
STARTUP_ORDER="${STARTUP_ORDER:-50}"
DISPLAY_MODE="${DISPLAY_MODE:-std}"
VM_DESCRIPTION="${VM_DESCRIPTION:-QEMU VM managed by infra-proxmox}"
VM_TAGS="${VM_TAGS:-managed}"

require_vmid VMID
require_positive_int SOCKETS
require_positive_int CORES
require_positive_int MEMORY_MB
require_positive_int BALLOON_MB
require_positive_int CPUUNITS
require_positive_int SYSTEM_DISK_GB
require_positive_int NIX_DISK_GB
require_positive_int WORK_DISK_GB
require_positive_int STARTUP_ORDER
require_bool ONBOOT

case "${DISPLAY_MODE}" in
  std|serial) ;;
  *)
    echo "ERROR: DISPLAY_MODE must be 'std' or 'serial', got: ${DISPLAY_MODE}" >&2
    exit 1
    ;;
esac

# std  = emulated VGA + USB tablet, drive via Proxmox Web UI noVNC console.
# serial = no VGA, no tablet, drive via `qm terminal`. Requires the guest
# image/ISO to be preconfigured for serial console (NixOS minimal ISO is not).
case "${DISPLAY_MODE}" in
  std)
    vga_arg="std"
    tablet_arg="1"
    ;;
  serial)
    vga_arg="serial0"
    tablet_arg="0"
    ;;
esac

if (( BALLOON_MB > MEMORY_MB )); then
  echo "ERROR: BALLOON_MB (${BALLOON_MB}) must be <= MEMORY_MB (${MEMORY_MB})" >&2
  exit 1
fi

cleanup_hint() {
  cat >&2 <<EOF

Creation failed or was interrupted.

Inspect with:

  qm config ${VMID} || true
  pvesm list ${LOCAL_DISK_STORAGE} | grep "vm-${VMID}" || true
  pvesm list ${NFS_STORAGE} | grep "vm-${VMID}" || true

Clean up with:

  qm stop ${VMID} || true
  qm destroy ${VMID} --purge --destroy-unreferenced-disks 1 || true

Then re-check orphaned volumes:

  pvesm list ${LOCAL_DISK_STORAGE} | grep "vm-${VMID}" || true
  pvesm list ${NFS_STORAGE} | grep "vm-${VMID}" || true

EOF
}

trap cleanup_hint ERR

if vm_exists "${VMID}"; then
  echo "ERROR: VMID ${VMID} already exists." >&2
  echo "Existing config:" >&2
  qm config "${VMID}" >&2 || true
  exit 1
fi

if ! storage_exists "${LOCAL_DISK_STORAGE}"; then
  echo "ERROR: storage not found: ${LOCAL_DISK_STORAGE}" >&2
  pvesm status >&2
  exit 1
fi

if ! storage_exists "${NFS_STORAGE}"; then
  echo "ERROR: storage not found: ${NFS_STORAGE}" >&2
  pvesm status >&2
  exit 1
fi

if ! pvesm path "${ISO_STORAGE}:iso/${ISO_FILE}" >/dev/null 2>&1; then
  echo "ERROR: ISO not found: ${ISO_STORAGE}:iso/${ISO_FILE}" >&2
  echo "Available ISO-like entries on ${ISO_STORAGE}:" >&2
  pvesm list "${ISO_STORAGE}" 2>/dev/null | grep -E 'iso|\.iso' >&2 || true
  exit 1
fi

if ! bridge_exists "${BRIDGE}"; then
  echo "ERROR: network bridge not found: ${BRIDGE}" >&2
  ip link show >&2
  exit 1
fi

total_vcpus=$(( SOCKETS * CORES ))

cat <<EOF
About to create Proxmox VM:

  env file:      ${VM_ENV}

  VMID:          ${VMID}
  Name:          ${NAME}
  ISO:           ${ISO_STORAGE}:iso/${ISO_FILE}
  Local storage: ${LOCAL_DISK_STORAGE}
  NFS storage:   ${NFS_STORAGE}
  Bridge:        ${BRIDGE}

  Sockets:       ${SOCKETS}
  Cores/socket:  ${CORES}
  Total vCPU:    ${total_vcpus}
  CPU units:     ${CPUUNITS}
  RAM max:       ${MEMORY_MB} MB
  RAM balloon:   ${BALLOON_MB} MB

  system disk:   ${SYSTEM_DISK_GB} GiB on ${LOCAL_DISK_STORAGE} (serial=system)
  /nix disk:     ${NIX_DISK_GB} GiB on ${LOCAL_DISK_STORAGE} (serial=nix)
  /work disk:    ${WORK_DISK_GB} GiB on ${NFS_STORAGE} (serial=work)

  onboot:        ${ONBOOT}$( ((ONBOOT)) && printf ' (startup order=%s)' "${STARTUP_ORDER}" )
  display:       ${DISPLAY_MODE} (vga=${vga_arg}, tablet=${tablet_arg}, serial0=socket)

EOF

CONFIRM="${CONFIRM:-}"
if [[ "${CONFIRM}" != "yes" ]]; then
  read -r -p "Create this VM? Type 'yes' to continue: " answer
  if [[ "${answer}" != "yes" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

echo "Creating VM ${VMID} (${NAME})..."

qm create "${VMID}" \
  --name "${NAME}" \
  --description "${VM_DESCRIPTION}" \
  --ostype l26 \
  --machine q35 \
  --bios ovmf \
  --agent enabled=1,fstrim_cloned_disks=1 \
  --tablet "${tablet_arg}" \
  --onboot "${ONBOOT}" \
  --tags "${VM_TAGS}"

if (( ONBOOT )); then
  qm set "${VMID}" --startup "order=${STARTUP_ORDER}"
fi

qm set "${VMID}" \
  --efidisk0 "${LOCAL_DISK_STORAGE}:1,efitype=4m,pre-enrolled-keys=0"

qm set "${VMID}" \
  --cpu host \
  --sockets "${SOCKETS}" \
  --cores "${CORES}" \
  --numa 1 \
  --cpuunits "${CPUUNITS}"

qm set "${VMID}" \
  --memory "${MEMORY_MB}" \
  --balloon "${BALLOON_MB}"

qm set "${VMID}" \
  --scsihw virtio-scsi-single \
  --scsi0 "${LOCAL_DISK_STORAGE}:${SYSTEM_DISK_GB},ssd=1,discard=on,iothread=1,serial=system" \
  --scsi1 "${LOCAL_DISK_STORAGE}:${NIX_DISK_GB},ssd=1,discard=on,iothread=1,serial=nix" \
  --scsi2 "${NFS_STORAGE}:${WORK_DISK_GB},iothread=1,serial=work"

qm set "${VMID}" \
  --ide2 "${ISO_STORAGE}:iso/${ISO_FILE},media=cdrom"

qm set "${VMID}" \
  --net0 "virtio,bridge=${BRIDGE},firewall=1"

qm set "${VMID}" \
  --boot "order=ide2;scsi0"

qm set "${VMID}" \
  --serial0 socket \
  --vga "${vga_arg}"

qm set "${VMID}" \
  --rng0 source=/dev/urandom

trap - ERR

echo
echo "VM created successfully."
echo
qm config "${VMID}"

case "${DISPLAY_MODE}" in
  std)
    console_hint=$'  qm start '"${VMID}"$'\n  # then open the Proxmox Web UI noVNC console for this VM'
    switch_hint=$'\nOptional — once the guest is configured for serial console, switch to headless:\n\n  qm set '"${VMID}"$' --vga serial0 --tablet 0\n  qm terminal '"${VMID}"$'\n'
    ;;
  serial)
    console_hint=$'  qm start '"${VMID}"$'\n  qm terminal '"${VMID}"
    switch_hint=""
    ;;
esac

cat <<EOF

Next commands:

${console_hint}

After the guest is installed, switch boot order to disk and detach ISO:

  qm set ${VMID} --boot "order=scsi0"
  qm set ${VMID} --delete ide2
${switch_hint}
Clean delete:

  qm stop ${VMID} || true
  qm destroy ${VMID} --purge --destroy-unreferenced-disks 1

EOF
