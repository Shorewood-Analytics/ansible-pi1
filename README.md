# pi1 configuration

**Fleet architecture revision:** [fleet design and qualification](docs/fleet.md)
describes standard Ansible inventory, reusable upstream collections, LAN and
Tailscale access, and the exact HA guarantees not yet established. The earlier
`recovery/` prototype is retained for inspection but is not the recommended
fleet implementation or a qualified recovery system.

The Pi is an operational target, not a build or test runner. GitHub-hosted
ARM64 CI builds Chawan in Debian 12, checks it, and publishes a commit-specific
candidate only after the configuration-tool checks pass. CI exercises Ansible,
Docker Compose and an ephemeral Kubernetes cluster on hosted machines; it does
not install those services on pi1.

## Install a CI candidate

Wait for the push workflow and its `build-<commit>` prerelease to succeed.
Substitute its full 40-character commit SHA, then paste this into a real SSH
terminal (not a pipeline):

```bash
(set -e; rev=FULL_40_CHARACTER_COMMIT_SHA; f=$(mktemp); curl -fL "https://raw.githubusercontent.com/Shorewood-Analytics/ansible-pi1/${rev}/scripts/bootstrap.sh" -o "$f"; bash "$f" "$rev")
```

Then start `~/.local/bin/chawan-ci -V`. The installer verifies bundle and file
checksums, keeps previous versions, and switches to the new version only after
the checks pass. It installs in the user's home directory without sudo. A
repeat install verifies the existing version and does not download it again.

The private files in `~/.logs/` record terminal input and output, timing, and a
separate stderr copy. **All input is recorded, including passwords.** Stop
recording before typing secrets. Logs are not uploaded. `scriptreplay` can use
the `.log` and `.log.timing` files. CI artifacts and logs do not establish a
backup or protect against an SD-card failure.

## Previous recovery prototype (superseded for fleet design)

The earlier PAT-based recovery prototype and its
[procedure](docs/recovery.md) remain available for comparison. They predate the
standard shared inventory and have not been qualified against a real private
GitHub repository. Do not treat this prototype as an established backup.
Real keys, inventories, volume identifiers and machine profiles must never be
added to this public repository. A Git subtree has no independent privacy.

## Validation boundaries

CI exercises downloads, terminal logging, integrity failures, interrupted runs,
and prebuilt ARM64 rendering. Recovery rehearsals use real Ansible/Vault and a
synthetic GitHub transport; they do not verify a live private-repository restore.
They do not establish Pi hardware health, thermal
margin, boot recovery, target connectivity, or field readiness. Actual deployment
and recovery procedures require the target's verified inventory, secure network
access and populated recovery profiles. Volume definitions are not volume data
backups; boot-image recovery and automatic HA promotion are not implemented.
Chawan has its own engine;
JavaScript and some modern sites may be unsupported.
