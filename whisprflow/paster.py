"""Clipboard + auto-paste at cursor position on macOS."""

import subprocess
import rumps


def paste_text(text: str) -> bool:
    """Copy text to clipboard and try to paste at cursor.
    Returns True if paste was attempted, False if only copied to clipboard."""
    # Always copy to clipboard first
    proc = subprocess.Popen(["pbcopy"], stdin=subprocess.PIPE)
    proc.communicate(text.encode("utf-8"))

    # Try to simulate Cmd+V
    try:
        result = subprocess.run(
            ["osascript", "-e",
             'tell application "System Events" to keystroke "v" using command down'],
            timeout=3,
            capture_output=True,
        )
        if result.returncode != 0:
            rumps.notification("WhisprFlow", "Copied to clipboard", "No text field focused — use Cmd+V to paste")
            return False
        return True
    except Exception:
        rumps.notification("WhisprFlow", "Copied to clipboard", "No text field focused — use Cmd+V to paste")
        return False
