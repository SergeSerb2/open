"""Best-effort process evidence for an interrupted real-App split flow."""
import subprocess


def frontmost_command(pid):
    """Read only PID/command, never the process environment or another app's UI."""
    if not isinstance(pid, int) or pid <= 0:
        return dict(status='UNAVAILABLE', reason='No frontmost PID was recorded')
    try:
        result = subprocess.run(['/bin/ps', '-ww', '-o', 'pid=,command=', '-p', str(pid)],
                                capture_output=True, text=True, timeout=2)
    except (OSError, subprocess.SubprocessError) as error:
        return dict(pid=pid, status='UNAVAILABLE', reason=type(error).__name__)
    fields = result.stdout.strip().split(None, 1)
    if result.returncode or len(fields) != 2 or fields[0] != str(pid):
        return dict(pid=pid, status='UNAVAILABLE', reason='Process exited before command capture')
    return dict(pid=pid, status='INFO', command=fields[1])
