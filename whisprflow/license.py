"""License key generation and validation for WhisprFlow.

Format: WF-XXXXX-XXXXX-XXXXX-XXXXX
Validation: HMAC-SHA256 based, fully offline.
"""

import hashlib
import hmac
import secrets
import string

SECRET = b"whisprflow-2026-lifetime-license-key-secret"
TRIAL_LIMIT = 50
PREFIX = "WF"


def _compute_signature(payload: str) -> str:
    sig = hmac.new(SECRET, payload.encode(), hashlib.sha256).hexdigest()[:20]
    return sig.upper()


def generate_license() -> str:
    """Generate a valid license key."""
    chars = string.ascii_uppercase + string.digits
    # Generate random payload (first 3 groups)
    groups = [
        "".join(secrets.choice(chars) for _ in range(5))
        for _ in range(3)
    ]
    payload = "-".join(groups)

    # Last group is derived from HMAC of the first 3
    sig = _compute_signature(payload)[:5]
    return f"{PREFIX}-{payload}-{sig}"


def validate_license(key: str) -> bool:
    """Validate a license key. Works fully offline."""
    if not key:
        return False

    key = key.strip().upper()
    parts = key.split("-")

    if len(parts) != 5:
        return False
    if parts[0] != PREFIX:
        return False

    # Each group should be 5 alphanumeric chars
    for part in parts[1:]:
        if len(part) != 5:
            return False
        if not part.isalnum():
            return False

    # Verify HMAC: last group must match signature of first 3 groups
    payload = "-".join(parts[1:4])
    expected_sig = _compute_signature(payload)[:5]

    return parts[4] == expected_sig


def is_licensed() -> bool:
    """Check if the app has a valid license."""
    from whisprflow import settings
    key = settings.get_license_key()
    return validate_license(key) if key else False


def is_trial_expired() -> bool:
    """Check if trial period (50 uses) is exhausted."""
    from whisprflow import settings
    return settings.get_trial_uses() >= TRIAL_LIMIT


def can_use() -> bool:
    """Check if the app can be used (licensed or within trial)."""
    return is_licensed() or not is_trial_expired()


def remaining_trial() -> int:
    """Return remaining trial uses."""
    from whisprflow import settings
    return max(0, TRIAL_LIMIT - settings.get_trial_uses())


# CLI: generate keys
if __name__ == "__main__":
    import sys
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 5
    print(f"Generating {n} license keys:\n")
    for _ in range(n):
        key = generate_license()
        valid = validate_license(key)
        print(f"  {key}  {'✅' if valid else '❌'}")
