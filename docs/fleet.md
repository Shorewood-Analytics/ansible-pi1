# Fleet design and qualification

This draft uses Ansible's standard inventory, group variables, host variables,
and pinned upstream collections. The old `recovery/` prototype is not the fleet
control plane. It remains in this draft for comparison; it has not been enrolled
against live private infrastructure and should not be assumed production-ready.

## Control plane

* Public GitHub Actions builds artifacts and validates generic automation with
  synthetic data on GitHub-hosted runners. No development, builds, or tests run
  on the Pi. Private repository workflows are not required.
* A separate private GitHub repo is intended to contain real `inventory/`,
  `group_vars/`, `host_vars/`, and Ansible Vault-encrypted secrets. A classic PAT
  can authenticate to this private repo; a PAT-retrievable private release asset
  for the vault key remains a proposed recovery approach, not a deployed store.
* Run Ansible on a controller with network access to the nodes. A GitHub-hosted
  runner has no automatic route into your tailnet or private LAN. A runner joined
  to Tailscale with narrowly scoped, ephemeral credentials is one option; a
  reachable operator/controller on the LAN is another. Neither is configured.
* Node identity, SSH host keys, network ACLs, service credentials and real
  addresses belong in the private inventory, not public CI logs.

The example inventory is illustrative documentation, not actual infrastructure.
`fleet_transport=lan` selects the local address; `fleet_transport=tailscale`
selects its tailnet address. Both are SSH transports to the same logical node.
The controller's health URLs must also be reachable over the selected network.

## Service plane

For an existing stateless service, deploy a pinned image on at least two
independent hosts. `playbooks/rolling-compose.yml` uses the upstream
`community.docker.docker_compose_v2` collection, checks every peer's health
before changing a host and uses upstream `community.general.haproxy` to drain
connections on every configured HAProxy. It applies one host at a time, waits
for recovery, re-enables the host, and stops at the first failure. Failed nodes
remain drained for investigation. **This does not roll back an update, control
other traffic paths, or establish that every real proxy is in the inventory.**

On a LAN, HAProxy can actively check and route to multiple backends. A single
proxy remains a single point of failure. Two independently hosted proxies plus
a tested shared-address failover mechanism (such as keepalived/VRRP on a
compatible LAN), or an existing redundant load balancer, are needed to remove
that point of failure. HTTPS requires an appropriate certificate trusted by the
clients; no real certificates or network bindings are provisioned here.

For tailnet clients, Tailscale Services can expose one HTTPS name across multiple
tagged service hosts. It requires compatible Tailscale clients, a configured
Service, tailnet policy, and host approvals. The exact selection behavior depends
on tailnet routing. Tailscale's service-host reachability is not proof that the
application is healthy; place application-aware health routing behind the
service and test it. Whether the required capabilities and number of users are
available at zero cost depends on the actual tailnet plan and usage.

Kubernetes is an optional future scheduler, not an automatic prerequisite for
the Pi. If selected, use `kubernetes.core` with readiness probes and rolling
updates. A highly available Kubernetes control plane requires additional nodes
and a qualified quorum/datastore; two nodes do not magically provide a resilient
etcd quorum. Neither Compose nor Kubernetes supplies safe data replication or
fencing merely by increasing replicas.

## Verification and remaining work

The public hosted rehearsal uses two disposable Compose projects and one
HAProxy with a temporary test certificate. It exercises the `community.docker`
and `community.general` modules, makes HTTPS requests during a rolling
recreation, refuses an update when the peer is down, and checks proxy routing
after either backend stops. Both
simulated nodes share one runner; this is not evidence of independent host,
network, proxy, tailnet, TLS, or storage failure recovery. The test-only nginx
tag is not a production release artifact. Pin production images by digest.

Before any production rollout, establish and test: a private inventory and
recoverable vault; a reachable and authenticated controller; actual image and
config distribution; service-specific readiness and draining on every ingress;
redundant ingress for each network; TLS and access rules; rollback; stateful
data replication, fencing and restore; and failover under continuous traffic.
Zero downtime, live failover, disaster recovery and a $0 Tailscale business plan
are **not established** by this draft.

## References

* [Ansible inventory and group variables](https://docs.ansible.com/projects/ansible/latest/inventory_guide/intro_inventory.html)
* [Ansible serial execution](https://docs.ansible.com/projects/ansible/latest/playbook_guide/playbooks_strategies.html)
* [Compose v2 module](https://docs.ansible.com/projects/ansible/latest/collections/community/docker/docker_compose_v2_module.html)
* [Tailscale Services](https://tailscale.com/docs/features/tailscale-services)
* [Kubernetes rolling updates](https://kubernetes.io/docs/tasks/run-application/update-deployment-rolling/)
* [K3s high availability](https://docs.k3s.io/datastore/ha-embedded)
