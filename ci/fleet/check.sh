#!/usr/bin/env bash
set -euo pipefail
if [[ ${GITHUB_ACTIONS:-} != true || ${RUNNER_ENVIRONMENT:-} != github-hosted ]]; then
    printf '%s\n' 'Fleet tests run only on GitHub-hosted CI.' >&2
    exit 1
fi
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
file="${root}/ci/fleet/compose.yml"
test_dir=$(mktemp -d)
pidfile="${test_dir}/proxy.pid"
probe_pid=
cleanup() {
    rm -f -- "${test_dir}/probe-running"
    if [[ -n ${probe_pid} ]]; then wait "${probe_pid}" 2>/dev/null || true; fi
    FLEET_CI_PORT=18101 docker compose -p fleet-ci-a -f "${file}" down --remove-orphans >/dev/null 2>&1 || true
    FLEET_CI_PORT=18102 docker compose -p fleet-ci-b -f "${file}" down --remove-orphans >/dev/null 2>&1 || true
    if [[ -s ${pidfile} ]]; then
        proxy_pid=$(<"${pidfile}")
        kill "${proxy_pid}" 2>/dev/null || true
    fi
    rm -rf -- "${test_dir}"
}
trap cleanup EXIT
FLEET_CI_PORT=18101 docker compose -p fleet-ci-a -f "${file}" up -d --wait
FLEET_CI_PORT=18102 docker compose -p fleet-ci-b -f "${file}" up -d --wait
openssl req -x509 -nodes -days 1 -newkey rsa:2048 -keyout "${test_dir}/key.pem" -out "${test_dir}/cert.pem" -subj /CN=localhost -addext subjectAltName=DNS:localhost >/dev/null 2>&1
cat "${test_dir}/cert.pem" "${test_dir}/key.pem" > "${test_dir}/server.pem"
sed "s|@TLS_PEM@|${test_dir}/server.pem|" "${root}/ci/fleet/haproxy.cfg" > "${test_dir}/haproxy.cfg"
haproxy -c -f "${test_dir}/haproxy.cfg"
haproxy -D -f "${test_dir}/haproxy.cfg" -p "${pidfile}"
for attempt in {1..20}; do
    if curl -fsS http://127.0.0.1:19080/ >/dev/null; then break; fi
    if [[ ${attempt} == 20 ]]; then exit 1; fi
    sleep 1
done
curl --cacert "${test_dir}/cert.pem" -fsS https://localhost:19443/ >/dev/null
args=(-i "${root}/ci/fleet/hosts.yml" "${root}/playbooks/rolling-compose.yml" -e fleet_apply=true -e fleet_transport=lan -e fleet_recreate=always -e "fleet_compose_project_dir=${root}/ci/fleet")
touch "${test_dir}/probe-running"
(
    while [[ -f ${test_dir}/probe-running ]]; do
        curl --cacert "${test_dir}/cert.pem" -fsS --max-time 3 https://localhost:19443/ >/dev/null || printf 'request failed\n' >> "${test_dir}/probe-errors"
        sleep 0.2
    done
) &
probe_pid=$!
ansible-playbook "${args[@]}"
rm -f -- "${test_dir}/probe-running"
wait "${probe_pid}"
probe_pid=
[[ ! -s ${test_dir}/probe-errors ]]
FLEET_CI_PORT=18102 docker compose -p fleet-ci-b -f "${file}" stop
if ansible-playbook "${args[@]}" --limit node_a; then
    printf '%s\n' 'Expected a failed peer health check to abort the rollout.' >&2
    exit 1
fi
curl -fsS http://127.0.0.1:18101/ >/dev/null
sleep 3
curl -fsS http://127.0.0.1:19080/ >/dev/null
curl --cacert "${test_dir}/cert.pem" -fsS https://localhost:19443/ >/dev/null
FLEET_CI_PORT=18102 docker compose -p fleet-ci-b -f "${file}" up -d --wait
FLEET_CI_PORT=18101 docker compose -p fleet-ci-a -f "${file}" stop
sleep 3
curl -fsS http://127.0.0.1:19080/ >/dev/null
curl --cacert "${test_dir}/cert.pem" -fsS https://localhost:19443/ >/dev/null
printf '%s\n' 'PASS: collection-based drain, HTTPS under rolling updates, unhealthy-peer abort and proxy failover.'
