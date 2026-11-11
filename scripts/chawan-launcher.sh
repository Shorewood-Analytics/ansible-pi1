#!/usr/bin/env bash
# Managed by ansible-pi1
set -euo pipefail
base="${HOME}/.local/share/chawan-ci/current"
export LD_LIBRARY_PATH="${base}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
exec "${base}/bin/cha" "$@"
