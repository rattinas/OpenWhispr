"""Detect the active (frontmost) application on macOS."""

from whisprflow.config import APP_PROFILES

try:
    from AppKit import NSWorkspace
    HAS_APPKIT = True
except ImportError:
    HAS_APPKIT = False


def get_frontmost_app() -> dict | None:
    """Return {'name': ..., 'bundleId': ...} of the frontmost app, or None."""
    if not HAS_APPKIT:
        return None
    try:
        app = NSWorkspace.sharedWorkspace().frontmostApplication()
        return {
            "name": app.localizedName(),
            "bundleId": app.bundleIdentifier(),
        }
    except Exception:
        return None


def get_tone_for_app(app_info: dict | None) -> str:
    """Return a tone instruction string based on the active app, or empty string."""
    if not app_info or not app_info.get("bundleId"):
        return ""

    bundle_id = app_info["bundleId"]
    for profile in APP_PROFILES.values():
        if bundle_id in profile["bundleIds"]:
            return profile["tone"]
    return ""
