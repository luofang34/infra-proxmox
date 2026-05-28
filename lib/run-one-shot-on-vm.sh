#!/usr/bin/env bash
#
# Wake an idle Proxmox VM, drive a single systemd unit to completion over
# SSH, and put the VM back to sleep. Intended for periodic / on-demand
# workloads that don't justify keeping the guest powered on full-time
# (e.g. the installer-ISO builder).
#
# Usage:
#   run-one-shot-on-vm.sh <VMID> <UNIT> <SSH_HOST> [SSH_USER]
#
# Arguments:
#   VMID      Proxmox VMID to start.
#   UNIT      systemd unit (service) to start --wait on the guest.
#   SSH_HOST  Hostname or IP reachable from this host once the guest is up
#             (typically a static address declared in the guest's NixOS
#             config; we do not depend on guest-agent IP discovery so the
#             same script works against guests that haven't yet booted
#             their agent).
#   SSH_USER  Optional, defaults to root.
#
# Environment overrides:
#   START_TIMEOUT_S  Max seconds to wait for SSH after `qm start`. Default 180.
#   STOP_TIMEOUT_S   Max seconds to wait for graceful `qm shutdown`. Default 60.
#   SSH_OPTS         Extra options passed to ssh. Default: -o BatchMode=yes
#                    -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5
#
# Exit semantics:
#   * Exits with the exit code of the remote `systemctl start --wait` if
#     the unit ran to completion.
#   * If the unit self-shuts down the guest (e.g. ExecStopPost / explicit
#     poweroff in the script), ssh returns 255 and the VM is already
#     powered off; this is treated as success provided the unit's prior
#     ActiveState was `active` or `inactive` (not `failed`).
#   * Any orchestration failure (start timeout, etc.) exits non-zero with
#     a descriptive message on stderr.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

if [[ $# -lt 3 || $# -gt 4 ]]; then
  echo "usage: $0 <VMID> <UNIT> <SSH_HOST> [SSH_USER]" >&2
  exit 2
fi

VMID="$1"
UNIT="$2"
SSH_HOST="$3"
SSH_USER="${4:-root}"

START_TIMEOUT_S="${START_TIMEOUT_S:-180}"
STOP_TIMEOUT_S="${STOP_TIMEOUT_S:-60}"
SSH_OPTS="${SSH_OPTS:--o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5}"

require_proxmox_host_tools
require_command ssh

require_vmid VMID

if ! vm_exists "${VMID}"; then
  echo "ERROR: VM ${VMID} does not exist on this Proxmox host." >&2
  exit 1
fi

ssh_target="${SSH_USER}@${SSH_HOST}"
read -ra ssh_opt_array <<<"${SSH_OPTS}"
ssh_cmd=(ssh "${ssh_opt_array[@]}" "${ssh_target}")

if vm_is_running "${VMID}"; then
  echo "[$(date +%T)] VM ${VMID} already running; skipping qm start."
else
  echo "[$(date +%T)] qm start ${VMID}"
  qm start "${VMID}"
fi

echo "[$(date +%T)] waiting up to ${START_TIMEOUT_S}s for ssh ${ssh_target}"
deadline=$(( $(date +%s) + START_TIMEOUT_S ))
until "${ssh_cmd[@]}" true 2>/dev/null; do
  if (( $(date +%s) >= deadline )); then
    echo "ERROR: ssh to ${ssh_target} did not come up within ${START_TIMEOUT_S}s" >&2
    exit 1
  fi
  sleep 3
done
echo "[$(date +%T)] ssh up"

echo "[$(date +%T)] systemctl start --wait ${UNIT}"
# Capture exit code without aborting the script — we want to inspect it
# and still attempt the shutdown step on failure.
unit_rc=0
"${ssh_cmd[@]}" "systemctl start --wait ${UNIT}" || unit_rc=$?

# A self-shutting unit (e.g. one that ends in `systemctl --no-block poweroff`)
# will drop our ssh connection; ssh then reports 255. Treat 255 as "ok if
# the unit didn't fail before powering off" by checking ActiveState only
# if we can still reach the VM. If the VM is gone, infer success from the
# absence of a "failed" trail.
if (( unit_rc == 255 )); then
  # SSH dropped without an explicit error. The likeliest cause is that the
  # unit's SuccessAction (e.g. poweroff) raced the response back to ssh —
  # the unit finished, systemd PID 1 powered the guest off, the ssh
  # channel closed mid-flight. `qm status` lags ssh by a second or two in
  # this case. Poll briefly before deciding.
  poll_deadline=$(( $(date +%s) + 10 ))
  while (( $(date +%s) < poll_deadline )); do
    if ! vm_is_running "${VMID}"; then
      echo "[$(date +%T)] ssh closed because the guest powered itself off; treating as success."
      unit_rc=0
      break
    fi
    sleep 2
  done
  if (( unit_rc == 255 )); then
    echo "WARNING: ssh returned 255 and VM still running after 10s; treating as failure." >&2
    unit_rc=1
  fi
elif (( unit_rc != 0 )); then
  echo "ERROR: unit ${UNIT} failed on guest (rc=${unit_rc})." >&2
  # Pull a journal tail for context, ignoring further failures.
  "${ssh_cmd[@]}" "journalctl -u ${UNIT} --no-pager -n 20" >&2 || true
fi

if vm_is_running "${VMID}"; then
  echo "[$(date +%T)] qm shutdown ${VMID} (timeout=${STOP_TIMEOUT_S}s)"
  if ! qm shutdown "${VMID}" --timeout "${STOP_TIMEOUT_S}" --forceStop 1; then
    echo "ERROR: graceful shutdown failed; falling back to qm stop." >&2
    qm stop "${VMID}" || true
  fi
else
  echo "[$(date +%T)] VM ${VMID} already off; no shutdown action."
fi

if (( unit_rc == 0 )); then
  echo "[$(date +%T)] done."
else
  echo "[$(date +%T)] done with unit failure (rc=${unit_rc})." >&2
fi

exit "${unit_rc}"
