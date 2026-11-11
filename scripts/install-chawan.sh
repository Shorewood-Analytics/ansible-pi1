#!/usr/bin/env bash
# Installs a GitHub-hosted ARM64 build. This script never compiles or tests.
set -euo pipefail
umask 077
revision=${CHAWAN_REVISION:?Use the repository bootstrap with a full commit SHA}
if [[ ! ${revision} =~ ^[0-9a-f]{40}$ ]]; then
    printf '%s\n' 'Invalid commit SHA.' >&2
    exit 2
fi
arch=$(dpkg --print-architecture)
if [[ ${arch} != arm64 ]]; then
    printf '%s\n' 'Requires 64-bit ARM Debian/Raspberry Pi OS.' >&2
    exit 1
fi
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root="${HOME}/.local/share/chawan-ci"
release_dir="${root}/releases/${revision}"
archive=chawan-arm64-bookworm.tar.gz
base="https://github.com/Shorewood-Analytics/ansible-pi1/releases/download/build-${revision}"
mkdir -p -- "${root}/releases" "${HOME}/.local/bin"

if [[ ! -f ${release_dir}/.complete || ! -x ${release_dir}/bin/cha ]]; then
    stage=$(mktemp -d "${root}/.install.XXXXXXXX")
    trap 'rm -rf -- "${stage}"' EXIT
    curl --fail --location --retry 5 --retry-all-errors --connect-timeout 20 --max-time 900 --proto '=https' --proto-redir '=https' "${base}/${archive}.sha256" -o "${stage}/checksum"
    curl --fail --location --retry 5 --retry-all-errors --connect-timeout 20 --max-time 900 --proto '=https' --proto-redir '=https' "${base}/${archive}" -o "${stage}/${archive}"
    read -r expected filename < "${stage}/checksum"
    if [[ ! ${expected} =~ ^[0-9a-f]{64}$ || ${filename} != "${archive}" ]]; then
        printf '%s\n' 'Malformed artifact checksum.' >&2
        exit 1
    fi
    (cd "${stage}" && printf '%s  %s\n' "${expected}" "${archive}" | sha256sum --check --status)
    mkdir -p -- "${stage}/bundle"
    tar -xzf "${stage}/${archive}" -C "${stage}/bundle" --no-same-owner
    test -x "${stage}/bundle/bin/cha"
    test -x "${stage}/bundle/libexec/chawan/cgi-bin/https"
    (cd "${stage}/bundle" && sha256sum --check --status SHA256SUMS)
    printf '%s\n' "${revision}" > "${stage}/bundle/.complete"
    if [[ -e ${release_dir} ]]; then
        printf 'Incomplete release directory exists: %s\n' "${release_dir}" >&2
        exit 1
    fi
    mv -- "${stage}/bundle" "${release_dir}"
fi
(cd "${release_dir}" && sha256sum --check --status SHA256SUMS)

launcher="${HOME}/.local/bin/chawan-ci"
if [[ -e ${launcher} ]] && ! grep -q '^# Managed by ansible-pi1$' "${launcher}"; then
    printf 'Refusing to replace an unmanaged launcher: %s\n' "${launcher}" >&2
    exit 1
fi
if [[ -L ${root}/current && -f ${launcher} ]]; then
    active=$(readlink -f -- "${root}/current")
    if [[ ${active} == "${release_dir}" ]] && cmp -s "${script_dir}/chawan-launcher.sh" "${launcher}"; then
        printf 'Already installed: %s\n' "${revision}"
        exit 0
    fi
fi
tmp_launcher=$(mktemp "${HOME}/.local/bin/.chawan-ci.XXXXXXXX")
install -m 700 "${script_dir}/chawan-launcher.sh" "${tmp_launcher}"
mv -f -- "${tmp_launcher}" "${launcher}"
link_dir=$(mktemp -d "${root}/.link.XXXXXXXX")
ln -s -- "${release_dir}" "${link_dir}/current"
mv -Tf -- "${link_dir}/current" "${root}/current"
rmdir -- "${link_dir}"
printf 'Installed prebuilt commit %s. Run: %s -V\n' "${revision}" "${launcher}"
