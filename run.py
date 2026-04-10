#!/usr/bin/env python3
"""Entry point for WhisprFlow."""

import AppKit

# Hide Python from Dock — menu bar only
info = AppKit.NSBundle.mainBundle().infoDictionary()
info["LSUIElement"] = "1"

from whisprflow.app import main

if __name__ == "__main__":
    main()
