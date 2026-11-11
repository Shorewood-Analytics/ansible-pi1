"""Exercise downloads, hash failures, stdin preservation and exit propagation."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(tempfile.mkdtemp(prefix='chawan-bootstrap-tests-'))
bin_dir = root / 'bin'
bin_dir.mkdir()
bundle = root / 'bundle'
bundle.mkdir()
bootstrap = Path(__file__).resolve().parents[1] / 'scripts/bootstrap.sh'
revision = 'a' * 40
worker = b'#!/bin/bash\nread -r value\nprintf "CHILD:%s\\n" "$value"\nexit 17\n'
(bundle / 'install-chawan-logged.sh').write_bytes(worker)
(bundle / 'install-chawan.sh').write_bytes(b'#!/bin/bash\nexit 99\n')
(bundle / 'chawan-launcher.sh').write_bytes(b'#!/bin/bash\nexit 0\n')
hashes = ''.join(hashlib.sha256((bundle / name).read_bytes()).hexdigest() + '  ' + name + '\n'
                 for name in ['install-chawan.sh', 'install-chawan-logged.sh', 'chawan-launcher.sh'])
(bundle / 'SHA256SUMS').write_text(hashes)
curl = bin_dir / 'curl'
curl.write_text('''#!/usr/bin/env python3
import os, sys
from pathlib import Path
args = sys.argv[1:]
url = next(a for a in args if a.startswith('https://'))
assert '/' + 'a' * 40 + '/scripts/' in url
if os.environ.get('FAIL_DOWNLOAD') == '1':
    sys.exit(22)
name = url.rsplit('/', 1)[-1]
output = args[args.index('--output') + 1]
Path(output).write_bytes((Path(os.environ['TEST_BUNDLE']) / name).read_bytes())
''')
curl.chmod(0o700)
env = dict(os.environ)
env['PATH'] = str(bin_dir) + os.pathsep + env['PATH']
env['TEST_BUNDLE'] = str(bundle)

def run(ref, expected, child=False, **extra):
    result = subprocess.run(['bash', str(bootstrap), ref], input='stdin-preserved\n',
                            text=True, capture_output=True, env={**env, **extra})
    assert result.returncode == expected, (result.returncode, result.stdout, result.stderr)
    assert ('CHILD:stdin-preserved' in result.stdout) == child

run(revision, 17, child=True)
print('PASS bootstrap: pinned downloads, verified bundle, preserved stdin and child exit')
(bundle / 'install-chawan.sh').write_text('tampered\n')
run(revision, 1)
print('PASS bootstrap rejects checksum mismatch before execution')
run(revision, 22, FAIL_DOWNLOAD='1')
print('PASS bootstrap rejects a failed download before execution')
run('main', 2)
print('PASS bootstrap requires an immutable commit SHA')
