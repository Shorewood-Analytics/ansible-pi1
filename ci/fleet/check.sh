#!/usr/bin/env bash
set -euo pipefail
if [[ ${GITHUB_ACTIONS:-} != true || ${RUNNER_ENVIRONMENT:-} != github-hosted ]]; then
    printf '%s\n' 'Fleet tests run only on GitHub-hosted CI.' >&2
    exit 1
fi
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
file="${root}/ci/fleet/compose.yml"
pidfile=$(mktemp)
cleanup() {
    FLEET_CI_PORT=18101 docker compose -p fleet-ci-a -f "${file}" down --remove-orphans >/dev/null 2>&1 || true
    FLEET_CI_PORT=18102 docker compose -p fleet-ci-b -f "${file}" down --remove-orphans >/dev/null 2>&1 || true
    if [[ -s ${pidfile} ]]; then
        proxy_pid=$(<"${pidfile}")
        kill "${proxy_pid}" 2>/dev/null || true
    fi
    rm -f -- "${pidfile}"
}
trap cleanup EXIT
FLEET_CI_PORT=18101 docker compose -p fleet-ci-a -f "${file}" up -d --wait
FLEET_CI_PORT=18102 docker compose -p fleet-ci-b -f "${file}" up -d --wait
haproxy -c -f "${root}/ci/fleet/haproxy.cfg"
haproxy -D -f "${root}/ci/fleet/haproxy.cfg" -p "${pidfile}"
for attempt in {1..20}; do
    if curl -fsS http://127.0.0.1:19080/ >/dev/null; then break; fi
    if [[ ${attempt} == 20 ]]; then exit 1; fi
    sleep 1
done
args=(-i "${root}/ci/fleet/hosts.yml" "${root}/playbooks/rolling-compose.yml" -e fleet_apply=true -e fleet_transport=lan -e "fleet_compose_project_dir=${root}/ci/fleet")
ansible-playbook "${args[@]}"
FLEET_CI_PORT=18102 docker compose -p fleet-ci-b -f "${file}" stop
if ansible-playbook "${args[@]}" --limit node_a; then
    printf '%s\n' 'Expected a failed peer health check to abort the rollout.' >&2
    exit 1
fi
curl -fsS http://127.0.0.1:18101/ >/dev/null
sleep 3
curl -fsS http://127.0.0.1:19080/ >/dev/null
FLEET_CI_PORT=18102 docker compose -p fleet-ci-b -f "${file}" up -d --wait
FLEET_CI_PORT=18101 docker compose -p fleet-ci-a -f "${file}" stop
sleep 3
curl -fsS http://127.0.0.1:19080/ >/dev/null
printf '%s\n' 'PASS: pinned Ansible collection, serial rollout, abort-on-unhealthy-peer and proxy failover.'
