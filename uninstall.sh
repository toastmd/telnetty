#!/bin/bash
# Removes Telnetty and its saved settings (bookmarks, text size).
set -e
rm -rf /Applications/Telnetty.app
defaults delete com.toastmd.telnetty 2>/dev/null || true
pkgutil --forget com.toastmd.telnetty 2>/dev/null || true
echo "Telnetty removed."
