#!/usr/bin/env bash
# End-to-end NixOS VM install: create the VM on the Proxmox host, boot
# the custom installer ISO, then run nixos-anywhere FROM the fleet
# builder so the closure is built there and copies builder -> target
# over the LAN (the target never builds and never needs build-sized
# RAM). Finishes by flipping boot order off the ISO and power-cycling.
#
# Unlike the other lib/ scripts this one runs on the OPERATOR
# WORKSTATION, not on the Proxmox host: it drives the hypervisor, the
# builder, and the target over ssh. Requirements:
#   - an ssh agent holding a key authorized for: root on the Proxmox
#     host, the builder's build user, and the installer ISO's root
#     (agent forwarding lets the builder reach the target as root)
#   - rsync on the workstation and the builder
#
# usage: install-vm.sh path/to/vm.env path/to/flake-dir [flake-attr]
#   flake-attr defaults to NAME from the env file.
# environment:
#   PVE_HOST  ssh destination of the hypervisor (default root@192.168.89.5)
#   BUILDER   ssh destination of the build user  (default nix-remote@192.168.89.200)
#   CONFIRM   set to "yes" to skip create-qemu-vm.sh's interactive prompt
#
# Client-side expansion inside ssh command strings is intentional
# throughout: VMID/addresses are validated locally and the remote side
# has no matching variables.
# shellcheck disable=SC2029
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

PVE_HOST="${PVE_HOST:-root@192.168.89.5}"
BUILDER="${BUILDER:-nix-remote@192.168.89.200}"

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 path/to/vm.env path/to/flake-dir [flake-attr]" >&2
  exit 2
fi

VM_ENV="$1"
FLAKE_DIR="$2"

if [[ ! -f "${VM_ENV}" ]]; then
  echo "ERROR: env file not found: ${VM_ENV}" >&2
  exit 1
fi
if [[ ! -f "${FLAKE_DIR}/flake.nix" ]]; then
  echo "ERROR: no flake.nix in flake dir: ${FLAKE_DIR}" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${VM_ENV}"
FLAKE_ATTR="${3:-${NAME}}"

for var in VMID NAME; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: ${var} not set by env file ${VM_ENV}" >&2
    exit 1
  fi
done

echo "==> ${NAME} (VMID ${VMID}): create on ${PVE_HOST}, install .#${FLAKE_ATTR} via ${BUILDER}"

# --- 1. Create the VM on the hypervisor and boot the installer ISO ----------
# A pre-existing VM (e.g. a retried run) is reused as-is rather than
# recreated, so a failure after this phase is retryable.
if ssh "${PVE_HOST}" "qm status ${VMID}" >/dev/null 2>&1; then
  echo "==> VMID ${VMID} already exists; skipping create"
else
  REMOTE_TMP="$(ssh "${PVE_HOST}" 'mktemp -d /tmp/install-vm.XXXXXX')"
  trap 'ssh "${PVE_HOST}" "rm -rf ${REMOTE_TMP}" 2>/dev/null || true' EXIT

  scp -q "${SCRIPT_DIR}/common.sh" "${SCRIPT_DIR}/create-qemu-vm.sh" "${VM_ENV}" \
    "${PVE_HOST}:${REMOTE_TMP}/"

  # -t keeps create-qemu-vm.sh's confirmation prompt usable when
  # CONFIRM is not pre-set.
  ssh -t "${PVE_HOST}" \
    "CONFIRM='${CONFIRM:-}' bash ${REMOTE_TMP}/create-qemu-vm.sh ${REMOTE_TMP}/$(basename "${VM_ENV}")"
fi

ssh "${PVE_HOST}" "qm status ${VMID} | grep -q running || qm start ${VMID}"

# --- 2. Wait for the guest agent and read the installer's DHCP address ------
echo "==> waiting for the installer to come up (guest agent + DHCP)"
INSTALLER_IP=""
for _ in $(seq 1 60); do
  # Full binary path: guest-exec spawns without a shell, and the NixOS
  # installer has no /usr/bin.
  INSTALLER_IP="$(ssh "${PVE_HOST}" "VMID=${VMID} bash -s" <<'EOF' || true
qm guest exec "${VMID}" -- /run/current-system/sw/bin/ip -4 -br addr 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("out-data",""))' 2>/dev/null \
  | awk '$1 != "lo" && $3 != "" { split($3, a, "/"); print a[1]; exit }'
EOF
)"
  [[ -n "${INSTALLER_IP}" ]] && break
  sleep 5
done
if [[ -z "${INSTALLER_IP}" ]]; then
  echo "ERROR: no DHCP address from the guest agent after 5 minutes" >&2
  exit 1
fi
echo "==> installer is at ${INSTALLER_IP}"

# --- 3. Ship the flake to the builder and run nixos-anywhere from there -----
echo "==> syncing flake to ${BUILDER} and installing"
ssh "${BUILDER}" "mkdir -p 'installs/${NAME}'"
rsync -az --delete --exclude .git "${FLAKE_DIR}/" "${BUILDER}:installs/${NAME}/"

# The installer generates a fresh host key on every boot; drop any
# stale entry the builder may have for a recycled DHCP address.
ssh "${BUILDER}" "ssh-keygen -R ${INSTALLER_IP} >/dev/null 2>&1 || true"

# Forward the caller's own agent socket explicitly: an IdentityAgent
# directive in ~/.ssh/config (e.g. a secure-enclave agent) would
# otherwise be what -A forwards, and its keys are typically not the
# ones baked into the installer ISO.
FWD_OPTS=(-A)
if [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
  FWD_OPTS+=(-o "IdentityAgent=${SSH_AUTH_SOCK}")
fi

# The ./ prefix keeps nix from treating the path as a registry name.
ssh "${FWD_OPTS[@]}" "${BUILDER}" \
  "nix run github:nix-community/nixos-anywhere -- \
     --flake \"./installs/${NAME}#${FLAKE_ATTR}\" \
     --target-host \"root@${INSTALLER_IP}\""

# --- 4. Boot from disk: drop the ISO, flip boot order, power-cycle ----------
# nixos-anywhere reboots the target, but the ISO is still first in the
# boot order, so the guest lands back in the installer; a hard stop is
# safe there and the restart boots the installed system.
echo "==> flipping boot order to disk and power-cycling"
ssh "${PVE_HOST}" \
  "qm set ${VMID} --boot order=scsi0 && qm set ${VMID} --delete ide2 && \
   qm stop ${VMID} --timeout 60 && qm start ${VMID}"

if [[ -n "${STATIC_IP:-}" ]]; then
  ADDR="${STATIC_IP%%/*}"
  echo "==> waiting for sshd on ${ADDR}"
  for _ in $(seq 1 60); do
    if nc -z -w 3 "${ADDR}" 22 2>/dev/null; then
      echo "==> ${NAME} is up at ${ADDR}"
      echo "    (if its host key changed: ssh-keygen -R ${ADDR})"
      exit 0
    fi
    sleep 5
  done
  echo "WARNING: ${NAME} not reachable on ${ADDR}:22 after 5 minutes; check the console" >&2
  exit 1
fi

echo "==> ${NAME} installed; no STATIC_IP in env, check its address on the console"
