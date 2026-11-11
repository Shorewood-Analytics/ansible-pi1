import errno
import os
from pathlib import Path
import pty
import select
import signal
import stat
import subprocess
import tempfile
import time

source_path = Path(__file__).resolve().parents[1] / 'scripts' / 'install-chawan-logged.sh'
source = source_path.read_text()
root = Path(tempfile.mkdtemp(prefix='chawan-logging-tests-'))
logdir = root / 'logs with spaces'
mockbin = root / 'mockbin'
mockbin.mkdir()
for name, body in {
    'dpkg': '#!/bin/sh\nprintf "%s\\n" arm64\n',
    'sudo': '#!/bin/sh\nexit 99\n',
    'date': '#!/bin/sh\nprintf "%s\\n" 20261110T235959Z\n',
    'tee': '#!/bin/sh\nif [ "${FAIL_TEE:-0}" = 1 ]; then\n  for arg in "$@"; do [ "$arg" != --append ] || exit 42; done\nfi\nexec /usr/bin/tee "$@"\n',
}.items():
    file = mockbin / name
    file.write_text(body)
    file.chmod(0o700)

prefix = source.split('bash "${CHAWAN_INSTALLER}"', 1)[0]
suffix = '\nINSTALLER\n' + source.split('\nINSTALLER\n', 1)[1]

def run_case(name, body, expect, send=None, fail_tee=False):
    candidate = root / (name + '.sh')
    text = prefix + body + suffix
    text = text.replace('log_dir="${HOME}/.logs"', 'log_dir=' + repr(str(logdir)))
    candidate.write_text(text)
    (root / 'install-chawan.sh').write_text('#!/bin/bash\nexit 99\n')
    before = set(logdir.glob('*.log')) if logdir.exists() else set()
    env = dict(os.environ)
    env['PATH'] = str(mockbin) + os.pathsep + env['PATH']
    env['TERM'] = 'xterm-256color'
    env['FAIL_TEE'] = '1' if fail_tee else '0'
    pid, fd = pty.fork()
    if pid == 0:
        os.execve('/bin/bash', ['bash', str(candidate)], env)
    data = bytearray()
    sent = False
    deadline = time.monotonic() + 15
    child_status = None
    try:
        while time.monotonic() < deadline:
            if select.select([fd], [], [], 0.1)[0]:
                try:
                    chunk = os.read(fd, 65536)
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        break
                    raise
                if not chunk:
                    break
                data.extend(chunk)
                if send is not None and not sent and b'INPUT_READY' in data:
                    os.write(fd, send)
                    sent = True
            ended, status = os.waitpid(pid, os.WNOHANG)
            if ended:
                child_status = status
                break
        else:
            os.kill(pid, signal.SIGKILL)
            raise AssertionError(name + ' hung: ' + repr(bytes(data)))
    finally:
        os.close(fd)
    if child_status is None:
        _, child_status = os.waitpid(pid, 0)
    result = os.waitstatus_to_exitcode(child_status)
    assert result == expect, (name, result, expect, data.decode(errors='replace'))
    new = set(logdir.glob('*.log')) - before
    assert len(new) == 1, (name, new)
    log = new.pop()
    assert log.name.startswith('.chawan-20261110T235959Z.')
    timing = Path(str(log) + '.timing')
    error_log = Path(str(log) + '.stderr')
    worker = Path(str(log) + '.sh')
    for file in (log, timing, error_log, worker):
        assert stat.S_IMODE(file.stat().st_mode) == 0o600, file
    assert stat.S_IMODE(logdir.stat().st_mode) == 0o700
    raw = log.read_bytes()
    timing_text = timing.read_text()
    assert 'START_TIME ' in timing_text and 'O ' in timing_text
    assert f'EXIT_CODE {expect}' in timing_text, timing_text
    if name == 'success':
        assert b'STDOUT_PROBE' in raw and b'STDERR_PROBE' in raw
        assert b'typed-input-123' in raw and b'RECEIVED:typed-input-123' in raw
        assert '\nI ' in timing_text
        assert error_log.read_bytes() == b'STDERR_PROBE\n'
        assert b'STDOUT_PROBE' not in error_log.read_bytes()
    if name == 'failure':
        assert b'FAILURE_PROBE' in raw and b'MUST_NOT_RUN' not in raw
        assert b'FAILURE_PROBE' in error_log.read_bytes()
    if name == 'interrupt':
        assert b'MUST_NOT_RUN' not in raw
    summary = subprocess.run(['scriptreplay', '--log-io', str(log), '--log-timing', str(timing), '--summary'], capture_output=True, text=True, check=True)
    assert 'COMMAND:' in summary.stdout, (summary.stdout, summary.stderr)
    print(f'PASS {name}: status={result}, fresh private logs, valid timing/replay metadata')
    return log, raw

first, first_bytes = run_case('success', '''printf 'STDOUT_PROBE\\n'
printf 'STDERR_PROBE\\n' >&2
printf 'INPUT_READY\\n'
IFS= read -r reply
printf 'RECEIVED:%s\\n' "${reply}"
''', 0, b'typed-input-123\n')
second, _ = run_case('failure', '''printf 'FAILURE_PROBE\\n' >&2
bash -c 'exit 37'
printf 'MUST_NOT_RUN\\n'
''', 37)
assert first != second and first.read_bytes() == first_bytes
print('PASS existing transcript preserved; same timestamp produces a different filename')
run_case('interrupt', '''printf 'INPUT_READY\\n'
IFS= read -r reply
printf 'MUST_NOT_RUN\\n'
''', 130, b'\x03')
run_case('logger_failure', '''printf 'STDOUT_ONLY\\n'
''', 74, fail_tee=True)
print('Test artifacts:', root)
