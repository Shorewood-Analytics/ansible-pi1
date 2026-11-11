"""Exercise installation, repeat use, and failed updates with fake artifacts."""
import hashlib
import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='chawan-install-tests-'))
node = root / 'node'
node.mkdir()
script_dir = root / 'scripts'
script_dir.mkdir()
installer = script_dir / 'install-chawan.sh'
source = (repo / 'scripts/install-chawan.sh').read_text()
source = source.replace('${HOME}/.local', str(node / '.local'))
installer.write_text(source)
(script_dir / 'chawan-launcher.sh').write_bytes((repo / 'scripts/chawan-launcher.sh').read_bytes())
mock = root / 'mock'
mock.mkdir()
(mock / 'dpkg').write_text('#!/bin/sh\nprintf "arm64\\n"\n')
(mock / 'curl').write_text('''#!/usr/bin/env python3
import os, sys
from pathlib import Path
args = sys.argv[1:]
url = next(a for a in args if a.startswith('https://'))
name = url.rsplit('/', 1)[-1]
output = args[args.index('-o') + 1]
Path(output).write_bytes((Path(os.environ['TEST_ARTIFACTS']) / name).read_bytes())
''')
for entry in mock.iterdir():
    entry.chmod(0o700)
artifacts = root / 'artifacts'
artifacts.mkdir()
archive = artifacts / 'chawan-arm64-bookworm.tar.gz'
with tarfile.open(archive, 'w:gz') as out:
    manifest = []
    for name in ['bin/cha', 'libexec/chawan/cgi-bin/https']:
        payload = b'#!/bin/sh\nexit 0\n'
        item = tarfile.TarInfo(name)
        item.mode, item.size = 0o755, len(payload)
        out.addfile(item, io.BytesIO(payload))
        manifest.append(hashlib.sha256(payload).hexdigest() + '  ' + name + '\n')
    payload = ''.join(manifest).encode()
    item = tarfile.TarInfo('SHA256SUMS')
    item.mode, item.size = 0o644, len(payload)
    out.addfile(item, io.BytesIO(payload))
checksum = artifacts / (archive.name + '.sha256')
checksum.write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + '  ' + archive.name + '\n')
env = dict(os.environ)
env['PATH'] = str(mock) + os.pathsep + env['PATH']
env['TEST_ARTIFACTS'] = str(artifacts)

def run(revision, expected):
    result = subprocess.run(['bash', str(installer)], env={**env, 'CHAWAN_REVISION': revision},
                            capture_output=True, text=True)
    assert result.returncode == expected, (result.returncode, result.stdout, result.stderr)

first = 'a' * 40
run(first, 0)
current = node / '.local/share/chawan-ci/current'
assert current.resolve().name == first
assert (node / '.local/bin/chawan-ci').is_file()
archive.unlink()
run(first, 0)
assert current.resolve().name == first
print('PASS prebuilt install and repeat install without network')
archive.write_bytes(b'corrupt artifact')
run('b' * 40, 1)
assert current.resolve().name == first
print('PASS corrupt update is rejected without replacing the active version')
(current / 'bin/cha').write_text('bit rot\n')
run(first, 1)
print('PASS existing installation corruption is detected on reuse')
