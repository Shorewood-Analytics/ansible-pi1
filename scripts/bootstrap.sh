#!/usr/bin/env bash
# Download a matched, immutable installer bundle without consuming terminal stdin.
set -euo pipefail
umask 077
if [[ $# -ne 1 || ! ${1:-} =~ ^[0-9a-f]{40}$ ]]; then
    printf '%s\n' 'Usage: bash bootstrap.sh FULL_40_CHARACTER_COMMIT_SHA' >&2
    exit 2
fi
revision=$1
bundle=$(mktemp -d "${TMPDIR:-/tmp}/chawan-run.XXXXXXXX")
base="https://raw.githubusercontent.com/Shorewood-Analytics/ansible-pi1/${revision}/scripts"
for name in SHA256SUMS install-chawan.sh install-chawan-logged.sh chawan-launcher.sh; do
    curl --fail --location --retry 3 --connect-timeout 20 --max-time 120 --proto '=https' --proto-redir '=https' "${base}/${name}" --output "${bundle}/${name}"
done
(
    cd "${bundle}"
    sha256sum --check SHA256SUMS
)
printf 'Using repository commit: %s\n' "${revision}"
export CHAWAN_REVISION="${revision}"
exec bash "${bundle}/install-chawan-logged.sh"
