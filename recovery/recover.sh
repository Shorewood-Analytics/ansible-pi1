#!/usr/bin/env bash
# Applies an existing configuration; never builds, develops, or runs a test suite.
set +x
set -euo pipefail
umask 077
if [[ $# -lt 2 || $# -gt 3 || ! $1 =~ ^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$ || ! $2 =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$ ]]; then
    printf '%s\n' 'Usage: bash recovery/recover.sh OWNER/PRIVATE_REPO PROFILE [CONFIG_COMMIT_SHA]' >&2
    exit 2
fi
config_repo=$1
profile=$2
config_revision=${3:-}
[[ -z ${config_revision} || ${config_revision} =~ ^[0-9a-f]{40}$ ]] || exit 2
recovery_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=recovery/common.sh
source "${recovery_root}/recovery/common.sh"
recovery_require
recovery_revision
recovery_workspace
recovery_token
recovery_private
if [[ -z ${config_revision} ]]; then
    config_revision=$(gh api "repos/${config_repo}/commits/HEAD" --jq '.sha')
fi
[[ ${config_revision} =~ ^[0-9a-f]{40}$ ]] || exit 1
timestamp=$(date -u +%FT%TZ)
printf '%s Resolving committed recovery configuration.\n' "${timestamp}"
gh api "repos/${config_repo}/tarball/${config_revision}" > "${recovery_work}/config.tar.gz"
python3 "${recovery_root}/recovery/config.py" extract "${recovery_work}/config.tar.gz" "${recovery_work}/config"
python3 "${recovery_root}/recovery/config.py" manifest "${recovery_work}/config/recovery.json" > "${recovery_work}/manifest"
mapfile -t manifest < "${recovery_work}/manifest"
if [[ ${manifest[0]} != "${tooling_revision}" ]]; then
    printf 'Configuration requires public tooling commit %s; checkout that commit and retry.\n' "${manifest[0]}" >&2
    exit 1
fi
test -f "${recovery_work}/config/profiles/${profile}.vault"
recovery_private
gh release download "${manifest[1]}" --repo "${config_repo}" --pattern "${manifest[2]}" --output "${recovery_work}/vault-password"
chmod 600 "${recovery_work}/vault-password"
test -s "${recovery_work}/vault-password"
unset GH_TOKEN
export ANSIBLE_LOCAL_TEMP="${recovery_work}/ansible-local"
export ANSIBLE_REMOTE_TEMP="${recovery_work}/ansible-remote"
export ANSIBLE_CONFIG="${recovery_root}/recovery/ansible.cfg"
ansible-vault view --vault-password-file "${recovery_work}/vault-password" "${recovery_work}/config/profiles/${profile}.vault" > "${recovery_work}/profile.json"
python3 "${recovery_root}/recovery/config.py" prepare "${recovery_work}/profile.json" "${recovery_work}/apply.json"
python3 - "${recovery_work}/apply.json" "${recovery_root}/scripts" > "${recovery_work}/inputs.json" <<'PY'
import json, sys
print(json.dumps({"recovery_profile": sys.argv[1], "recovery_scripts": sys.argv[2]}))
PY
printf 'Applying configuration %s with tooling %s.\n' "${config_revision}" "${tooling_revision}"
ansible-playbook -i localhost, -c local "${recovery_root}/recovery/restore.yml" \
    -e "@${recovery_work}/inputs.json"
timestamp=$(date -u +%FT%TZ)
printf '%s Recovery configuration applied.\n' "${timestamp}"
