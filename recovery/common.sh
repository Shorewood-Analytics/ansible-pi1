#!/usr/bin/env bash
# Sourced only by the recovery entry points. Never enable tracing here.
recovery_require() {
    local tool
    for tool in gh git python3 ansible-vault ansible-playbook findmnt; do
        command -v "${tool}" >/dev/null || {
            printf 'Missing %s; install the distribution packages ansible-core, gh, git and util-linux.\n' "${tool}" >&2
            return 1
        }
    done
}

recovery_workspace() {
    [[ $(findmnt -n -o FSTYPE --target /dev/shm) == tmpfs ]] || {
        printf '%s\n' 'Recovery requires /dev/shm on tmpfs for temporary credentials.' >&2
        return 1
    }
    recovery_work=$(mktemp -d /dev/shm/pi-recovery.XXXXXXXX)
    export GH_CONFIG_DIR="${recovery_work}/gh"
    export GH_HOST=github.com GH_PROMPT_DISABLED=1
    unset GH_DEBUG GITHUB_TOKEN
    trap 'unset GH_TOKEN; rm -rf -- "${recovery_work}"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

recovery_token() {
    if [[ -z ${GH_TOKEN:-} ]]; then
        IFS= read -r -s -p 'GitHub classic PAT (repo scope; hidden): ' GH_TOKEN </dev/tty
        printf '\n' >/dev/tty
    fi
    [[ -n ${GH_TOKEN:-} ]] || { printf '%s\n' 'A PAT is required.' >&2; return 1; }
    export GH_TOKEN
}

recovery_private() {
    local visibility
    visibility=$(gh api "repos/${config_repo}" --jq '.visibility')
    [[ ${visibility} == private ]] || {
        printf '%s\n' 'Refusing to read or write recovery material in a non-private repository.' >&2
        return 1
    }
}

recovery_revision() {
    tooling_revision=$(git -C "${recovery_root}" rev-parse HEAD)
    [[ ${tooling_revision} =~ ^[0-9a-f]{40}$ ]]
    git -C "${recovery_root}" diff --quiet HEAD -- recovery scripts || {
        printf '%s\n' 'Use a clean, commit-pinned public tooling checkout.' >&2
        return 1
    }
}
