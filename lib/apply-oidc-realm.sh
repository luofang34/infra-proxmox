#!/usr/bin/env bash
# Apply (create or converge) an OIDC realm on a PVE node from a
# proxmox/oidc-*.env declaration, grant the declared admin ACLs, and
# verify the authorize hop end to end.
#
# Idempotent: safe to re-run any time, including after the node is
# rebuilt onto proxmox-nixos — realm config is pmxcfs STATE and does not
# follow the host's nix configuration; this script is its reconciler.
#
# Usage:
#   OIDC_CLIENT_KEY=<secret> lib/apply-oidc-realm.sh proxmox/oidc-rauthy.env [root@node]
#
# The client secret is intentionally an environment variable: its
# canonical store is the IdP itself. PVE persists it in pmxcfs
# (/etc/pve/domains.cfg, plaintext, root-readable) — a known PVE
# property, not a choice this script makes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/common.sh"

ENV_FILE="${1:?usage: OIDC_CLIENT_KEY=<secret> apply-oidc-realm.sh proxmox/oidc-<realm>.env [root@node]}"
NODE_SSH="${2:-root@192.168.89.5}"

# shellcheck disable=SC1090
source "${ENV_FILE}"
require_var REALM
require_var ISSUER_URL
require_var CLIENT_ID
require_var USERNAME_CLAIM
require_var OIDC_CLIENT_KEY

REDIRECT_URL="https://$(echo "${NODE_SSH}" | cut -d@ -f2):8006"

echo "== realm '${REALM}' on ${NODE_SSH} =="
if ssh "${NODE_SSH}" "pveum realm list --output-format json" | grep -q "\"${REALM}\""; then
  # username-claim is fixed at creation; PVE refuses it on modify.
  ssh "${NODE_SSH}" "pveum realm modify '${REALM}' \
    --issuer-url '${ISSUER_URL}' \
    --client-id '${CLIENT_ID}' \
    --client-key '${OIDC_CLIENT_KEY}' \
    --autocreate ${AUTOCREATE:-1} \
    --prompt '${PROMPT:-login}' \
    --scopes '${SCOPES:-openid email profile}'"
  echo "converged existing realm"
else
  ssh "${NODE_SSH}" "pveum realm add '${REALM}' --type openid \
    --issuer-url '${ISSUER_URL}' \
    --client-id '${CLIENT_ID}' \
    --client-key '${OIDC_CLIENT_KEY}' \
    --username-claim '${USERNAME_CLAIM}' \
    --autocreate ${AUTOCREATE:-1} \
    --prompt '${PROMPT:-login}' \
    --scopes '${SCOPES:-openid email profile}'"
  echo "created realm"
fi

echo "== admin ACLs =="
for email in ${ADMIN_USERS:-}; do
  userid="${email}@${REALM}"
  ssh "${NODE_SSH}" "pveum user add '${userid}' --comment 'Rauthy operator (ACL declared in infra-proxmox)' 2>/dev/null || true"
  ssh "${NODE_SSH}" "pveum acl modify / --users '${userid}' --roles Administrator"
  echo "  Administrator on / -> ${userid}"
done

echo "== verify the authorize hop (no browser needed) =="
AUTH_URL=$(ssh "${NODE_SSH}" "pvesh create /access/openid/auth-url --realm '${REALM}' --redirect-url '${REDIRECT_URL}' --output-format json" | tr -d '"')
echo "authorize URL: ${AUTH_URL%%\?*}?..."
fail=0
case "${AUTH_URL}" in
  "${ISSUER_URL}"*) echo "  ok: issued by our IdP" ;;
  *) echo "  FAIL: unexpected issuer in ${AUTH_URL}" ; fail=1 ;;
esac
echo "${AUTH_URL}" | grep -q "client_id=${CLIENT_ID}" && echo "  ok: client_id" || { echo "  FAIL: client_id missing"; fail=1; }
echo "${AUTH_URL}" | grep -q "prompt=login" && echo "  ok: prompt=login (forced re-auth)" || { echo "  FAIL: prompt=login missing"; fail=1; }
echo "${AUTH_URL}" | grep -q "code_challenge" && { echo "  note: PVE sent PKCE — clear this in docs AND set challenges on the Rauthy client"; } || echo "  ok: no PKCE sent (Rauthy client must keep challenges cleared)"
exit ${fail}
