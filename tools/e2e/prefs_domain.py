"""One private preferences domain per e2e process tree (LEAD 10:45, test isolation).

An automation build launched with OPEN_E2E_PREFERENCES_DOMAIN keeps every preference there, never in the user's
`io.github.sergeserb2.open`. `domain()` returns this run's name, creating it once and exporting it in os.environ so
that every App this process launches inherits it. The creator deletes the domain at exit.
"""
import atexit
import os
import subprocess
import uuid

REAL = 'io.github.sergeserb2.open'
PREFIX = REAL + '.e2e.'
ENV = 'OPEN_E2E_PREFERENCES_DOMAIN'


def remove(name):
    if not name.startswith(PREFIX): raise ValueError('refusing to delete a preferences domain that is not an e2e domain')
    subprocess.run(['/usr/bin/defaults', 'delete', name], capture_output=True)
    try: os.unlink(os.path.expanduser('~/Library/Preferences/' + name + '.plist'))
    except OSError: pass


def domain():
    name = os.environ.get(ENV)
    if not name:
        name = PREFIX + 'p%d-%s' % (os.getpid(), uuid.uuid4().hex[:8])
        os.environ[ENV] = name
        atexit.register(remove, name)
    if not name.startswith(PREFIX): raise ValueError(ENV + ' must start with ' + PREFIX)
    return name


def real_snapshot():
    """The user's real domain, read only: for the 'untouched' proof."""
    return subprocess.run(['/usr/bin/defaults', 'export', REAL, '-'], capture_output=True).stdout
