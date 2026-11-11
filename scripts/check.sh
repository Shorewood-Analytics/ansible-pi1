#!/usr/bin/env bash
set -euo pipefail
if [[ ${GITHUB_ACTIONS:-} != true || ${RUNNER_ENVIRONMENT:-} != github-hosted ]]; then
    printf '%s\n' 'Run this test suite on GitHub-hosted CI, never on the Pi.' >&2
    exit 1
fi
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "${script_dir}/.."
worker=$(mktemp)
trap 'rm -f -- "${worker}"' EXIT
awk "/^tee .*<<'INSTALLER'$/ { capture=1; next } /^INSTALLER$/ { capture=0 } capture" scripts/install-chawan-logged.sh > "${worker}"
test -s "${worker}"
check_status=0
for file in scripts/*.sh ci/*.sh ci/fleet/*.sh recovery/*.sh "${worker}"; do
    bash -n "${file}" || check_status=1
    shellcheck --external-sources --enable=all --severity=style "${file}" || check_status=1
done
[[ ${check_status} == 0 ]]
(cd scripts && sha256sum --check SHA256SUMS)
python3 tests/test_logging.py
python3 tests/test_bootstrap.py
python3 tests/test_install.py
