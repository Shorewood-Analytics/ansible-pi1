#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "${script_dir}/.."
worker=$(mktemp)
trap 'rm -f -- "${worker}"' EXIT
awk "/^tee .*<<'INSTALLER'$/ { capture=1; next } /^INSTALLER$/ { capture=0 } capture" scripts/install-chawan-logged.sh > "${worker}"
test -s "${worker}"
for file in scripts/*.sh ci/*.sh recovery/*.sh "${worker}"; do
    bash -n "${file}"
    shellcheck --enable=all --severity=style "${file}"
done
(cd scripts && sha256sum --check SHA256SUMS)
python3 tests/test_logging.py
python3 tests/test_bootstrap.py
python3 tests/test_install.py
