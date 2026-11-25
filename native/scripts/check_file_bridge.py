"""Exercise the real AppKit bridge in synthetic-only storage; no model or network."""
import json
import select
import subprocess
import sys
import time


def check(executable, env=None):
    process = subprocess.Popen([str(executable), '--bridge', '--bridge-self-test'],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, env=env)
    def request(value):
        raw = value if isinstance(value, bytes) else json.dumps(value).encode()
        process.stdin.write(raw + b'\n')
        process.stdin.flush()
        if not select.select([process.stdout], [], [], 10)[0]:
            raise AssertionError('bridge response timed out')
        return json.loads(process.stdout.readline())
    try:
        first = request({'action': 'event-loop-probe'})
        assert first['mainThread'] is True
        time.sleep(.15)  # Regression: AppKit must pump events while stdin is idle.
        second = request({'action': 'event-loop-probe'})
        assert second['ticks'] > first['ticks'], 'AppKit event loop stopped during stdin wait'
        assert request(b'not json')['status'] == 'indeterminate'
        assert request(b'x' * 131073)['status'] == 'indeterminate'
        assert request({'action': 'role', 'role': 'auditor-a'})['status'] == 'selected'
        for level in (2, 3):
            assert request({'action': 'select'})['status'] == 'selected'
            result = request({'action': 'save', 'level': level})
            assert result['resource']['level'] == level
            assert request({'action': 'lookup'})['resource'] == result['resource']
            assert request({'action': 'verify'})['status'] == 'verified'
        assert request({'action': 'role', 'role': 'user-b'})['status'] == 'selected'
        assert request({'action': 'save', 'level': 1})['status'] == 'indeterminate'
        # Reimporting the same synthetic path replaces its active registration.
        assert request({'action': 'list'})['files'] == [result['resource']]
        assert request({'action': 'event-loop-probe'})['ticks'] >= second['ticks']
        process.stdin.close()
        assert process.wait(timeout=10) == 0, 'EOF did not terminate bridge'
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
    # One-shot mode consumes exactly one command even if another is available.
    one = subprocess.run([str(executable), '--bridge-self-test'],
                         input=b'{"action":"list"}\n{"action":"list"}\n',
                         capture_output=True, timeout=10, env=env)
    assert one.returncode == 0 and len(one.stdout.splitlines()) == 1
    empty = subprocess.run([str(executable), '--bridge', '--bridge-self-test'],
                           input=b'', capture_output=True, timeout=10, env=env)
    assert empty.returncode == 0 and not empty.stdout
    print('PASS AppKit bridge: idle heartbeat, main-thread serial state, consecutive imports, malformed/oversize recovery, roles, one-shot and EOF; synthetic only')


if __name__ == '__main__':
    check(sys.argv[1])
