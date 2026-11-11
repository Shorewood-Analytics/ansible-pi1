#!/usr/bin/env python3
"""Hosted-CI recovery rehearsal: real Ansible/Vault, synthetic GitHub transport."""
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("recovery_config", ROOT / "recovery/config.py")
CONFIG = importlib.util.module_from_spec(spec)
spec.loader.exec_module(CONFIG)

MOCK_GH = r'''#!/usr/bin/env python3
import hashlib, io, json, os, pathlib, sys, tarfile
a = sys.argv[1:]
path = pathlib.Path(os.environ["FAKE_GITHUB_STATE"])
s = json.loads(path.read_text())
def option(name, default=None):
    return a[a.index(name)+1] if name in a else default
def save():
    path.write_text(json.dumps(s))
def fail():
    save(); sys.exit(1)
def emit(value):
    save(); print(value); sys.exit(0)
s.setdefault("workspaces", []).append(str(pathlib.Path(os.environ["GH_CONFIG_DIR"]).parent))
if os.environ.get("GH_TOKEN") != "ci-synthetic-pat": fail()
if a[0] == "api":
    method = option("--method", "GET")
    endpoint = a[1] if a[1] != "--method" else a[3]
    fields = {}
    for i, arg in enumerate(a[:-1]):
        if arg in ("-f", "-F"):
            k,v = a[i+1].split("=",1); fields[k] = v
    if endpoint == "orgs/example/repos" and method == "POST":
        if s.get("exists"): fail()
        assert fields["private"] == "true"
        s.update(exists=True, visibility="private", enabled=True, head="1"*40, files={"README.md":"Private recovery configuration\n"})
        emit("{}")
    if not s.get("exists"): fail()
    if endpoint == "repos/example/private-config":
        query = option("--jq")
        emit(s["visibility"] if query == ".visibility" else "main" if query == ".default_branch" else "{}")
    if endpoint.endswith("/actions/permissions"):
        if method == "PUT":
            assert fields["enabled"] == "false"
            s["enabled"] = False; emit("{}")
        emit(str(s["enabled"]).lower())
    if "/git/ref/heads/" in endpoint or endpoint.endswith("/commits/HEAD"):
        emit(s["head"])
    if "/git/commits/" in endpoint:
        emit("2"*40)
    if "/tarball/" in endpoint:
        out=io.BytesIO()
        with tarfile.open(fileobj=out,mode="w:gz") as tar:
            root=tarfile.TarInfo("snapshot/"); root.type=tarfile.DIRTYPE; tar.addfile(root)
            for name, content in s["files"].items():
                blob=content.encode(); member=tarfile.TarInfo("snapshot/"+name); member.size=len(blob)
                tar.addfile(member,io.BytesIO(blob))
        save(); sys.stdout.buffer.write(out.getvalue()); sys.exit(0)
    if endpoint.endswith("/git/trees") and method == "POST":
        assert not s["enabled"] and s["visibility"] == "private"
        body=json.loads(pathlib.Path(option("--input")).read_text())
        s["pending"]={entry["path"]:entry["content"] for entry in body["tree"]}
        assert all(name == "recovery.json" or (name.startswith("profiles/") and content.startswith("$ANSIBLE_VAULT;")) for name, content in s["pending"].items())
        emit("2"*40)
    if endpoint.endswith("/git/commits") and method == "POST":
        s["next_head"]=hashlib.sha1(json.dumps(s["pending"],sort_keys=True).encode()).hexdigest()
        emit(s["next_head"])
    if "/git/refs/heads/" in endpoint and method == "PATCH":
        assert fields["force"] == "false"
        if s.get("conflict"): fail()
        s["head"]=fields["sha"]; s["files"].update(s["pending"]); emit("{}")
elif a[:2] == ["release", "view"]:
    if a[2] not in s.get("keys", {}): fail()
    emit("exists")
elif a[:2] == ["release", "create"]:
    assert not s["enabled"] and s["visibility"] == "private"
    s.setdefault("keys",{})[a[2]]=pathlib.Path(a[-1]).read_text(); emit("created")
elif a[:2] == ["release", "download"]:
    if a[2] not in s.get("keys",{}): fail()
    key="wrong-key" if s.get("wrong_key") else s["keys"][a[2]]
    pathlib.Path(option("--output")).write_text(key); emit("")
fail()
'''


class Recovery(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="pi-recovery-ci-")
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.home_tmp = tempfile.TemporaryDirectory(prefix=".pi-recovery-ci-", dir=Path.home())
        self.addCleanup(self.home_tmp.cleanup)
        self.dest = Path(self.home_tmp.name) / "settings" / ".env"
        self.relative = str(self.dest.relative_to(Path.home()))
        self.secret = "TOKEN=ci-only-do-not-log\nLITERAL={{ keep_me_literal }}\nUNICODE=é\n"
        self.profile = {"schema": 1, "role": "shadow", "files": [{"path": self.relative, "content": self.secret}], "mounts": [], "packages": [], "chawan_revision": None}
        self.source = self.work / "profile.json"
        self.source.write_text(json.dumps(self.profile))
        self.state = self.work / "github.json"
        self.state.write_text(json.dumps({"exists": False}))
        self.bin = self.work / "bin"
        self.bin.mkdir()
        gh = self.bin / "gh"
        gh.write_text(MOCK_GH)
        gh.chmod(0o700)
        self.env = dict(os.environ, PATH=str(self.bin)+os.pathsep+os.environ["PATH"], GH_TOKEN="ci-synthetic-pat", FAKE_GITHUB_STATE=str(self.state))

    def run_script(self, script, *args, success=True):
        result = subprocess.run(["bash", str(ROOT / "recovery" / script), *args], env=self.env, text=True, capture_output=True, timeout=150)
        output = result.stdout + result.stderr
        self.assertNotIn(self.secret, output)
        self.assertNotIn("TOKEN=ci-only-do-not-log", output)
        self.assertNotIn("ci-synthetic-pat", output)
        for folder in json.loads(self.state.read_text()).get("workspaces", []):
            self.assertFalse(Path(folder).exists(), "temporary recovery credentials were retained")
        if success:
            self.assertEqual(result.returncode, 0, output)
        else:
            self.assertNotEqual(result.returncode, 0)
        return output

    def publish(self):
        self.run_script("publish-profile.sh", "example/private-config", "shadow", str(self.source))
        state = json.loads(self.state.read_text())
        self.assertFalse(state["enabled"])
        self.assertEqual(state["visibility"], "private")
        self.assertTrue(state["files"]["profiles/shadow.vault"].startswith("$ANSIBLE_VAULT;"))
        self.assertNotIn("ci-only-do-not-log", json.dumps(state["files"]))
        self.assertNotIn("vault-password", state["files"])
        return state

    def test_publish_restore_and_repeat_are_recoverable_and_idempotent(self):
        state = self.publish()
        output = self.run_script("recover.sh", "example/private-config", "shadow", state["head"])
        self.assertIn("Recovery configuration applied", output)
        self.assertEqual(self.dest.read_text(), self.secret)
        self.assertEqual(self.dest.stat().st_mode & 0o777, 0o600)
        before = self.dest.stat().st_mtime_ns
        output = self.run_script("recover.sh", "example/private-config", "shadow", state["head"])
        self.assertRegex(output, r"changed=0\b")
        self.assertEqual(self.dest.stat().st_mtime_ns, before)

    def test_public_repository_is_rejected_before_secret_upload(self):
        self.state.write_text(json.dumps({"exists": True, "visibility": "public"}))
        self.run_script("publish-profile.sh", "example/private-config", "shadow", str(self.source), success=False)
        self.assertNotIn("keys", json.loads(self.state.read_text()))
        self.run_script("recover.sh", "example/private-config", "shadow", success=False)
        self.assertFalse(self.dest.exists())

    def test_wrong_vault_key_cannot_modify_destination(self):
        state = self.publish()
        state["wrong_key"] = True
        self.state.write_text(json.dumps(state))
        self.run_script("recover.sh", "example/private-config", "shadow", success=False)
        self.assertFalse(self.dest.exists())

    def test_missing_volume_stops_before_configuration_writes(self):
        self.profile["mounts"] = [{"path": str(self.work / "absent-volume"), "uuid": "0000-1111"}]
        self.source.write_text(json.dumps(self.profile))
        self.publish()
        self.run_script("recover.sh", "example/private-config", "shadow", success=False)
        self.assertFalse(self.dest.exists())

    def test_symlink_parent_is_rejected(self):
        self.publish()
        elsewhere = self.work / "elsewhere"
        elsewhere.mkdir()
        self.dest.parent.symlink_to(elsewhere, target_is_directory=True)
        self.run_script("recover.sh", "example/private-config", "shadow", success=False)
        self.assertFalse((elsewhere / ".env").exists())

    def test_concurrent_private_update_is_not_force_pushed(self):
        state = self.publish()
        head = state["head"]
        state["conflict"] = True
        self.state.write_text(json.dumps(state))
        self.run_script("publish-profile.sh", "example/private-config", "shadow", str(self.source), success=False)
        self.assertEqual(json.loads(self.state.read_text())["head"], head)

    def test_archive_rejects_links_and_traversal(self):
        for index, name in enumerate(("snapshot/../../escape", "snapshot/link")):
            archive = self.work / f"bad-{index}.tar.gz"
            with tarfile.open(archive, "w:gz") as tar:
                item = tarfile.TarInfo(name)
                item.type = tarfile.SYMTYPE
                item.linkname = "/etc/passwd"
                tar.addfile(item)
            with self.assertRaises(ValueError):
                CONFIG.extract(archive, self.work / f"output-{index}")

    def test_profile_rejects_unpinned_packages_and_path_escape(self):
        bad = dict(self.profile, packages=["tmux"])
        with self.assertRaises(ValueError):
            CONFIG.profile(bad)
        bad = dict(self.profile, files=[{"path": "../escape", "content": "synthetic"}])
        with self.assertRaises(ValueError):
            CONFIG.profile(bad)


if __name__ == "__main__":
    if not os.environ.get("GITHUB_ACTIONS"):
        raise SystemExit("Run recovery rehearsals on GitHub-hosted CI, never on the Pi.")
    unittest.main(verbosity=2)
