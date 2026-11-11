#!/usr/bin/env bash
# Create or update the private recovery store. No private Actions are used.
set +x
set -euo pipefail
umask 077
if [[ $# -ne 3 || ! $1 =~ ^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$ || ! $2 =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$ ]]; then
    printf '%s\n' 'Usage: bash recovery/publish-profile.sh OWNER/PRIVATE_REPO PROFILE PROFILE_JSON' >&2
    exit 2
fi
config_repo=$1
profile=$2
profile_source=$(realpath -- "$3")
recovery_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=recovery/common.sh
source "${recovery_root}/recovery/common.sh"
recovery_require
recovery_revision
python3 "${recovery_root}/recovery/config.py" profile "${profile_source}"
recovery_workspace
recovery_token
if ! gh api "repos/${config_repo}" > "${recovery_work}/repo.json" 2> "${recovery_work}/api-error"; then
    # A failed create (including an inaccessible existing repository) stops here.
    gh api --method POST "orgs/${config_repo%/*}/repos" \
        -f "name=${config_repo#*/}" -F private=true -F auto_init=true \
        -F has_issues=false -F has_wiki=false > "${recovery_work}/repo.json"
fi
recovery_private
# This must succeed before any secret or encrypted profile is uploaded.
gh api --method PUT "repos/${config_repo}/actions/permissions" -F enabled=false >/dev/null
[[ $(gh api "repos/${config_repo}/actions/permissions" --jq '.enabled') == false ]]
branch=$(gh api "repos/${config_repo}" --jq '.default_branch')
[[ ${branch} =~ ^[A-Za-z0-9_.-]+$ ]] || { printf '%s\n' 'Use a simple default branch name.' >&2; exit 1; }
parent=$(gh api "repos/${config_repo}/git/ref/heads/${branch}" --jq '.object.sha')
base_tree=$(gh api "repos/${config_repo}/git/commits/${parent}" --jq '.tree.sha')
gh api "repos/${config_repo}/tarball/${parent}" > "${recovery_work}/existing.tar.gz"
python3 "${recovery_root}/recovery/config.py" extract "${recovery_work}/existing.tar.gz" "${recovery_work}/existing"
mkdir -p "${recovery_work}/changes/profiles"
if [[ -f ${recovery_work}/existing/recovery.json ]]; then
    python3 "${recovery_root}/recovery/config.py" manifest "${recovery_work}/existing/recovery.json" > "${recovery_work}/manifest"
    mapfile -t manifest < "${recovery_work}/manifest"
    [[ ${manifest[0]} == "${tooling_revision}" ]] || {
        printf 'Use tooling commit %s to update this recovery store.\n' "${manifest[0]}" >&2
        exit 1
    }
    key_release=${manifest[1]}
    key_asset=${manifest[2]}
else
    key_release=recovery-key-v1
    key_asset=vault-password
    python3 - "${tooling_revision}" > "${recovery_work}/changes/recovery.json" <<'PY'
import json, sys
print(json.dumps({"schema": 1, "tooling_revision": sys.argv[1],
                  "key_release": "recovery-key-v1", "key_asset": "vault-password"}, indent=2))
PY
fi
if gh release view "${key_release}" --repo "${config_repo}" >/dev/null 2>&1; then
    gh release download "${key_release}" --repo "${config_repo}" --pattern "${key_asset}" --output "${recovery_work}/vault-password"
else
    # Never generate a replacement key for an existing recovery manifest.
    [[ ! -f ${recovery_work}/existing/recovery.json ]] || {
        printf '%s\n' 'Existing recovery key is unavailable; refusing to replace it.' >&2
        exit 1
    }
    python3 -c 'import secrets; print(secrets.token_hex(32))' > "${recovery_work}/vault-password"
    recovery_private
    gh release create "${key_release}" --repo "${config_repo}" --target "${parent}" \
        --title 'Private Ansible recovery key v1' \
        --notes 'Recovery key. Repository readers can retrieve this asset and decrypt recovery profiles. Retain it for historical restores.' \
        "${recovery_work}/vault-password" >/dev/null
fi
chmod 600 "${recovery_work}/vault-password"
# Verify the authoritative remote key before publishing any ciphertext.
gh release download "${key_release}" --repo "${config_repo}" --pattern "${key_asset}" --output "${recovery_work}/remote-key"
cmp -s "${recovery_work}/vault-password" "${recovery_work}/remote-key"
test -s "${recovery_work}/vault-password"
ansible-vault encrypt --vault-password-file "${recovery_work}/vault-password" \
    --output "${recovery_work}/changes/profiles/${profile}.vault" "${profile_source}" >/dev/null
python3 "${recovery_root}/recovery/config.py" tree "${recovery_work}/changes" "${base_tree}" > "${recovery_work}/tree.json"
tree=$(gh api --method POST "repos/${config_repo}/git/trees" --input "${recovery_work}/tree.json" --jq '.sha')
commit=$(gh api --method POST "repos/${config_repo}/git/commits" -f "message=Update encrypted recovery profile ${profile}" -f "tree=${tree}" -f "parents[]=${parent}" --jq '.sha')
recovery_private
# A concurrent writer causes a non-fast-forward error instead of losing updates.
gh api --method PATCH "repos/${config_repo}/git/refs/heads/${branch}" -f "sha=${commit}" -F force=false >/dev/null
[[ $(gh api "repos/${config_repo}/git/ref/heads/${branch}" --jq '.object.sha') == "${commit}" ]]
printf 'Published encrypted configuration %s; private Actions are disabled.\n' "${commit}"
printf 'Restore from the pinned public checkout: bash recovery/recover.sh %q %q %q\n' "${config_repo}" "${profile}" "${commit}"
