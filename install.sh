#!/bin/bash
# install.sh - Install kvm-appvm host components
#
# This script sets up the host-side components:
# - Creates log directory
# - Installs QEMU hook symlink
# - Prints instructions for guest-side installation

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/var/log/kvm-appvm"
HOOK_SOURCE="$SCRIPT_DIR/hooks/qemu"
HOOK_TARGET="/etc/libvirt/hooks/qemu"

echo "=== kvm-appvm Host Installation ==="
echo

# Check if running as root or with sudo
if [[ $EUID -ne 0 ]]; then
    echo "This script requires root privileges."
    echo "Please run with: sudo $0"
    exit 1
fi

# Create log directory
echo "Creating log directory: $LOG_DIR"
mkdir -p "$LOG_DIR"
chmod 755 "$LOG_DIR"
echo "  Done."
echo

# Handle QEMU hook installation
echo "Installing QEMU hook..."

if [[ -e "$HOOK_TARGET" ]]; then
    if [[ -L "$HOOK_TARGET" ]]; then
        # It's a symlink - check if it points to our script
        current_target=$(readlink -f "$HOOK_TARGET")
        if [[ "$current_target" == "$HOOK_SOURCE" ]]; then
            echo "  QEMU hook already installed correctly."
        else
            echo "  Existing symlink found pointing to: $current_target"
            echo "  Backing up to: ${HOOK_TARGET}.backup"
            mv "$HOOK_TARGET" "${HOOK_TARGET}.backup"
            ln -s "$HOOK_SOURCE" "$HOOK_TARGET"
            echo "  Created new symlink: $HOOK_TARGET -> $HOOK_SOURCE"
        fi
    else
        # It's a regular file - back it up
        echo "  Existing hook file found."
        echo "  Backing up to: ${HOOK_TARGET}.backup"
        mv "$HOOK_TARGET" "${HOOK_TARGET}.backup"
        ln -s "$HOOK_SOURCE" "$HOOK_TARGET"
        echo "  Created symlink: $HOOK_TARGET -> $HOOK_SOURCE"
    fi
else
    # Create hooks directory if needed
    mkdir -p "$(dirname "$HOOK_TARGET")"
    ln -s "$HOOK_SOURCE" "$HOOK_TARGET"
    echo "  Created symlink: $HOOK_TARGET -> $HOOK_SOURCE"
fi
echo

# Verify hook is executable
if [[ ! -x "$HOOK_SOURCE" ]]; then
    chmod +x "$HOOK_SOURCE"
    echo "Made hook script executable."
fi

echo "=== Host Installation Complete ==="
echo
echo "The appvm command is ready to use from: $SCRIPT_DIR/appvm"
echo "You may want to add it to your PATH or create a symlink:"
echo "  sudo ln -s $SCRIPT_DIR/appvm /usr/local/bin/appvm"
echo
echo "=== Guest Installation Instructions ==="
echo
echo "To enable Work VM functionality, install these files in your template VM:"
echo
echo "1. Copy the init script:"
echo "   sudo cp $SCRIPT_DIR/guest/appvm-init /usr/local/bin/appvm-init"
echo "   sudo chmod +x /usr/local/bin/appvm-init"
echo
echo "2. Copy the systemd unit:"
echo "   sudo cp $SCRIPT_DIR/guest/appvm-init.service /etc/systemd/system/"
echo
echo "3. Enable the service:"
echo "   sudo systemctl daemon-reload"
echo "   sudo systemctl enable appvm-init.service"
echo
echo "4. Shut down the template VM to save changes."
echo
