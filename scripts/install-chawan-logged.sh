#!/usr/bin/env bash
# Debian / Raspberry Pi OS, ARM64. Run with bash, not sh or sudo.
# Records all terminal input, including anything typed with echo disabled.
# .log = terminal input + combined output; .timing = event times and stream IDs;
# .stderr = separate stderr copy; .sh = exact installer source supplied to tee.
set -euo pipefail
umask 077

if [[ ${EUID} -eq 0 ]]; then
    printf '%s\n' 'Run this as your normal user; individual install steps use sudo.' >&2
    exit 1
fi
if [[ ! -t 0 || ! -t 1 ]]; then
    printf '%s\n' 'Run from an interactive SSH/tmux terminal, not a pipeline.' >&2
    exit 1
fi
for dependency in bash dpkg sudo script tee mktemp date; do
    command -v "${dependency}" >/dev/null || {
        printf 'Missing command: %s\n' "${dependency}" >&2
        exit 1
    }
done
architecture=$(dpkg --print-architecture)
if [[ ${architecture} != arm64 ]]; then
    printf '%s\n' 'This installer requires 64-bit ARM Debian/Raspberry Pi OS.' >&2
    exit 1
fi

log_dir="${HOME}/.logs"
if [[ -L ${log_dir} ]]; then
    printf 'Refusing a symlink as the log directory: %s\n' "${log_dir}" >&2
    exit 1
fi
mkdir -p -- "${log_dir}"
chmod 700 -- "${log_dir}"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
session_log=$(mktemp "${log_dir}/.chawan-${stamp}.XXXXXX.log")
timing_log="${session_log}.timing"
stderr_log="${session_log}.stderr"
worker="${session_log}.sh"
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# Reserve the companion files without overwriting any existing file.
(
    set -o noclobber
    : > "${timing_log}"
    : > "${stderr_log}"
    : > "${worker}"
)

tee "${worker}" >/dev/null <<'INSTALLER'
#!/usr/bin/env bash
set -euo pipefail
umask 077
: "${CHAWAN_STDERR:?Missing stderr log path}"
: "${CHAWAN_INSTALLER:?Missing installer path}"

# Mirror stderr to its own file while retaining it in the terminal transcript.
exec {error_terminal}>&2
# The process-substitution status is checked explicitly by wait in finish().
# shellcheck disable=SC2312
exec 2> >(tee --ignore-interrupts --output-error=exit --append "${CHAWAN_STDERR}" >&"${error_terminal}")
error_logger=$!
finish() {
    status=$?
    trap - EXIT
    exec 2>&"${error_terminal}"
    exec {error_terminal}>&-
    if wait "${error_logger}"; then
        :
    else
        printf '%s\n' 'The stderr log could not be completed.' >&2
        if [[ ${status} -eq 0 ]]; then
            status=74
        fi
    fi
    exit "${status}"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

bash "${CHAWAN_INSTALLER}"

INSTALLER

export CHAWAN_STDERR="${stderr_log}" CHAWAN_INSTALLER="${script_dir}/install-chawan.sh"
printf -v run_command 'exec bash %q' "${worker}"
printf 'Log: %s\nTiming: %s\nStderr: %s\n' "${session_log}" "${timing_log}" "${stderr_log}"
printf '%s\n' 'Recording includes ALL typed input, including sudo passwords. Logs are private (0600).'
status=0
SHELL=/bin/bash TZ=UTC script --quiet --return --flush \
    --log-io "${session_log}" --log-timing "${timing_log}" \
    --logging-format advanced --command "${run_command}" || status=$?
printf 'Finished with status %s. Log: %s\n' "${status}" "${session_log}"
if [[ ${status} -eq 0 ]]; then
    printf '%s\n' 'To browse without recording: ~/.local/bin/chawan-ci -V'
fi
exit "${status}"
