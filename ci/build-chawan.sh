#!/usr/bin/env bash
# Runs only in the GitHub-hosted Debian ARM64 build container.
set -euo pipefail
if [[ ${GITHUB_ACTIONS:-} != true || ${RUNNER_ENVIRONMENT:-} != github-hosted ]]; then
    printf '%s\n' 'Compilation is restricted to GitHub-hosted CI.' >&2
    exit 1
fi
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y build-essential curl ca-certificates xz-utils pkg-config libssl-dev libssh2-1-dev libbrotli-dev binutils
work=$(mktemp -d)
cd "${work}"
curl -fL --retry 3 https://nim-lang.org/download/nim-2.2.12-linux_arm64.tar.xz -o nim.tar.xz
printf '%s  %s\n' 3dc04191af72a8310cf1c8ffb6f772cc3716fc5f264bc7c453ab4aecb4085221 nim.tar.xz | sha256sum -c -
tar -xf nim.tar.xz
curl -fL --retry 3 https://git.sr.ht/~bptato/chawan/archive/v0.5.2.tar.gz -o chawan.tar.gz
printf '%s  %s\n' 21201936aa3a5ff0117fd55bfa1805ab77647761f4341fd2f77eca15bb66c807 chawan.tar.gz | sha256sum -c -
tar -xf chawan.tar.gz
cd chawan-v0.5.2
export PATH="${work}/nim-2.2.12/bin:${PATH}"
make -j2 TARGET=release-nolto NIM=nim
make install TARGET=release-nolto DESTDIR="${work}/staging" PREFIX=/usr/local
bundle="${work}/staging/usr/local"
mkdir -p "${bundle}/lib" /src/dist
find "${bundle}/bin" "${bundle}/libexec" -type f -executable -print0 > "${work}/executables"
while IFS= read -r -d '' executable; do
    if ldd "${executable}" > "${work}/ldd" 2>/dev/null; then
        awk '$2 == "=>" && $3 ~ /^\// {print $1, $3}' "${work}/ldd" > "${work}/sonames"
        while read -r soname location; do
            case "${soname}" in libc.so.*|libm.so.*|libpthread.so.*|libdl.so.*|librt.so.*|ld-linux-*) continue ;; *) : ;; esac
            cp -L -- "${location}" "${bundle}/lib/${soname}"
        done < "${work}/sonames"
    fi
done < "${work}/executables"
export LD_LIBRARY_PATH="${bundle}/lib"
"${bundle}/bin/cha" -v
printf '<html><body>CI_RENDER_OK</body></html>\n' > "${work}/test.html"
"${bundle}/bin/cha" --dump "${work}/test.html" | grep -q CI_RENDER_OK
(cd "${bundle}" && find bin lib libexec -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
tar -C "${bundle}" -czf /src/dist/chawan-arm64-bookworm.tar.gz bin lib libexec SHA256SUMS
cd /src/dist
sha256sum chawan-arm64-bookworm.tar.gz > chawan-arm64-bookworm.tar.gz.sha256
