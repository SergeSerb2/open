"""Display identity for replay; raw ICC hashes and transient CG IDs stay in receipts."""
import re

SCHEME = 'icc-header-v1'
DIGEST = re.compile(r'[0-9a-f]{64}')
IDENTITY_FIELDS = {'id', 'icc_sha256', 'icc_digest_scheme', 'icc_header_sha256'}


def normalized_digest(screen, peer):
    raw = screen.get('icc_sha256')
    if not isinstance(raw, str) or not DIGEST.fullmatch(raw):
        return None
    scheme = screen.get('icc_digest_scheme')
    digest = screen.get('icc_header_sha256')
    if scheme == SCHEME and isinstance(digest, str) and DIGEST.fullmatch(digest):
        return digest
    # Historical receipts have only a raw hash. The migrated reference binds
    # that exact raw hash to the proven normalized digest; no unknown alias.
    if scheme is None and digest is None and raw == peer.get('icc_sha256'):
        digest = peer.get('icc_header_sha256')
        if peer.get('icc_digest_scheme') == SCHEME and isinstance(digest, str) and DIGEST.fullmatch(digest):
            return digest
    return None


def displays_match(expected, actual):
    if {k: v for k, v in expected.items() if k != 'screens'} != {k: v for k, v in actual.items() if k != 'screens'}:
        return False
    left, right = expected.get('screens', []), actual.get('screens', [])
    if not left or len(left) != len(right):
        return False
    for a, b in zip(left, right):
        if not any(k in s for s in (a, b) for k in ('icc_digest_scheme', 'icc_header_sha256')):
            if a != b: return False  # Unmigrated references keep their strict raw guard.
            continue
        first, second = normalized_digest(a, b), normalized_digest(b, a)
        if first is None or first != second:
            return False
        # All mode, backing-scale, hardware and any future colour fields stay
        # exact. Only raw ICC header identity and transient CG ID are excluded.
        if {k: v for k, v in a.items() if k not in IDENTITY_FIELDS} != {k: v for k, v in b.items() if k not in IDENTITY_FIELDS}:
            return False
    return True
