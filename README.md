# pi1 configuration

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

## Validation boundaries

CI exercises downloads, terminal logging, integrity failures, interrupted runs,
and prebuilt ARM64 rendering. It does not establish Pi hardware health, thermal
margin, boot recovery, target connectivity, or field readiness. Actual deployment
and recovery procedures require the target's verified inventory, secure network
access and a separately qualified recovery system. Chawan has its own engine;
JavaScript and some modern sites may be unsupported.
