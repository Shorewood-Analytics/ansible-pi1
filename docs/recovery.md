# Recovery from GitHub

## Storage and cost boundary

| Location | Contents | Execution |
| --- | --- | --- |
| Public tooling repo | Generic Ansible, installers, tests and ARM64 build inputs | All builds and tests use standard GitHub-hosted runners |
| Private configuration repo | Commit-pinned host profiles, encrypted with Ansible Vault | Actions disabled by the initialization command |
| Private release asset | Recoverable vault password, versioned as `recovery-key-v1/vault-password` | Downloaded using the same PAT |
| Runtime host | Installed binaries and the configuration needed to run them | Configuration application only; no builds or test suites |

This is an access-controlled recovery store, not isolation from repository
readers or GitHub. Anyone who can read the private repo and release asset can
decrypt the profiles. Separating the key from Git history protects ordinary
repository clones from containing both halves; it does not defeat a stolen PAT.
Use a classic PAT with `repo` scope for the requested single-token workflow;
organization SSO authorization may also be required. Do not store that PAT in
the recovery repo, a command argument, shell history, or a terminal recording.
The scripts prompt without echo and remove their temporary copies on exit.

Private repos are available on GitHub Free. An **internal** repo is an Enterprise
visibility tier shared across the enterprise; it is unsuitable for this boundary.
Standard hosted public CI is free under GitHub's applicable usage policy. This
design does not consume private Actions minutes or use paid larger runners.
No S3, cloud subscription, private Actions workflow, or Pi-hosted runner is used.

Actions secrets cannot be read back as plaintext through the REST API; they are
not an independent PAT-recoverable backup. Repository secrets alone therefore
cannot satisfy this recovery design.

## Prerequisites

Use a booted Debian/Raspberry Pi OS host with Bash, Python 3, Git, curl,
`ansible-core`, `gh`, and util-linux. Install missing distribution packages once:

```bash
sudo apt-get update && sudo apt-get install -y ansible-core gh git curl ca-certificates util-linux
```

These are binary package installations, not compilation or development jobs.
Run recovery as the intended runtime user, not through `sudo bash`.
Root is needed only when the profile explicitly requests package installation;
obtain a sudo credential (`sudo -v`) before restoring that kind of profile.
Temporary plaintext uses `/dev/shm`; tmpfs can be swapped by the OS. This does
not provide protection against privileged users or a compromised running host.

Use a clean checkout of the exact public tooling commit that passed CI. Do not
run recovery within `script --log-io` or any other full-input transcript. The
older Chawan terminal recorder is a separate, optional operation and is never
invoked by recovery.

## Enroll selected configuration

Capture only files and volumes selected for the profile. The example below
does not presume those paths exist on a real host:

```bash
python3 recovery/capture.py --role primary --file .tmux.conf --file .config/science/app.env --mount /mnt/data --package tmux --output /dev/shm/recovery-capture.json
bash recovery/publish-profile.sh OWNER/PRIVATE_CONFIG_REPO primary /dev/shm/recovery-capture.json
```

The capture records literal text, explicit Debian package versions and existing
filesystem UUIDs. Add `--chawan-revision FULL_SHA` to install that published ARM64
candidate on restore. It does not search indiscriminately for credentials or
copy all dotfiles. Inspect the selected profile locally; its contents are secret.
Publish asks for one PAT, creates the private organization repo if absent,
disables its Actions, and uploads the encrypted profile. It fails before
uploading secrets if repository visibility is public or internal.

The command prints the committed configuration SHA. After confirming publication,
delete the temporary plaintext capture. To update a profile, capture again and
repeat publication from the tooling version pinned in the private manifest.
Old encrypted commits remain recoverable with their corresponding retained key.
Never delete or overwrite a recovery key while historical profiles depend on it.

## Recreate another host

From the public tooling checkout, using the same classic PAT:

```bash
bash recovery/recover.sh OWNER/PRIVATE_CONFIG_REPO primary FULL_CONFIG_COMMIT_SHA
```

Omitting the final SHA resolves the private default branch once and reports the
selected immutable commit. Each run verifies private visibility, downloads that
snapshot and the private key asset, decrypts into temporary storage, validates
the profile, and applies Ansible. No credential is saved by `gh auth login`.
The original Pi is not contacted and is not required.

Recovery refuses a missing or mismatched required mount before changing files;
it does not format disks, create filesystems, change fstab or mount unknown media.
It restores only the explicitly selected user files, with mode 0600 and secret
output suppressed. It preserves literal `.env` values instead of interpreting
them as templates. An unchanged file is not rewritten. Package versions must
still exist in the configured Debian repositories; absence fails rather than
silently choosing a newer version. Exact OS-image/package retention is a further
qualification step, not something the current Chawan artifact provides.

## Multiple hosts and recovery limits

Publish separate `primary`, `shadow` or `peer` profiles as appropriate. Their role
is metadata in this initial implementation; it does not implement fencing,
replication, service promotion or automatic failover. Do not copy unique host
identities or shared-writer service credentials to a shadow indiscriminately.

This restores selected configuration and access material, not an SD-card image,
research datasets or mutable volume contents. Those data still require an
independently stored, consistent backup or replica. GitHub configuration storage
must not be represented as an unlimited disk-backup service.

The initial hosted rehearsal verifies real Ansible Vault encryption/decryption,
private/public visibility checks, idempotent file restoration, literal secret
content, temporary-credential cleanup, missing volumes, wrong keys, unsafe
archives, symlink parents and conflicting configuration updates. GitHub transport
in that rehearsal is synthetic; a live PAT/private-store round trip remains
unqualified until a real private repo and selected profiles have been enrolled.

## Primary references

- [GitHub Actions billing](https://docs.github.com/en/actions/concepts/billing-and-usage)
- [Repository visibility](https://docs.github.com/en/repositories/creating-and-managing-repositories/about-repositories)
- [Disable Actions through repository permissions](https://docs.github.com/en/rest/actions/permissions#set-github-actions-permissions-for-a-repository)
- [Actions secret API](https://docs.github.com/en/rest/actions/secrets)
- [Ansible Vault and its security boundary](https://docs.ansible.com/projects/ansible/latest/vault_guide/vault.html)
- [Vault password storage](https://docs.ansible.com/projects/ansible/latest/vault_guide/vault_managing_passwords.html)
- [Authenticated release downloads](https://cli.github.com/manual/gh_release_download)
