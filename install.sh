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

# Tracks whether install.sh added or changed the hook this run.
# libvirtd only registers hooks at daemon start / reload, so any change
# requires a `systemctl reload` for VMs to actually invoke the hook.
HOOK_CHANGED=0

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

# Handle QEMU hook installation.
#
# We *copy* the hook into /etc/libvirt/hooks/ rather than symlinking it.
# AppArmor's libvirtd profile (Debian/Ubuntu) restricts hook execution to
# /etc/libvirt/hooks/**, so a symlink to a script under /home/... is
# refused with "Permission denied" even though file modes look fine.
# Trade-off: the user must re-run install.sh after editing hooks/qemu.
echo "Installing QEMU hook..."
mkdir -p "$(dirname "$HOOK_TARGET")"

if [[ -L "$HOOK_TARGET" ]]; then
    echo "  Removing legacy symlink at $HOOK_TARGET"
    rm -f "$HOOK_TARGET"
fi

if [[ -e "$HOOK_TARGET" ]] && cmp -s "$HOOK_SOURCE" "$HOOK_TARGET"; then
    echo "  QEMU hook already up to date."
else
    if [[ -e "$HOOK_TARGET" ]]; then
        echo "  Existing hook differs - backing up to: ${HOOK_TARGET}.backup"
        mv "$HOOK_TARGET" "${HOOK_TARGET}.backup"
    fi
    install -m 0755 "$HOOK_SOURCE" "$HOOK_TARGET"
    echo "  Installed: $HOOK_TARGET (copied from $HOOK_SOURCE)"
    HOOK_CHANGED=1
fi
echo

# Reload libvirtd so the hook is registered. Without this the daemon
# silently ignores the hook and overlay disks never get created on start.
if [[ "$HOOK_CHANGED" -eq 1 ]]; then
    for unit in libvirtd virtqemud; do
        if systemctl list-unit-files "$unit.service" >/dev/null 2>&1 \
                && systemctl is-active --quiet "$unit"; then
            echo "Reloading $unit so the new hook is picked up..."
            if systemctl reload "$unit"; then
                echo "  Reloaded $unit."
            else
                echo "  WARNING: Failed to reload $unit. Run 'sudo systemctl reload $unit' manually."
            fi
        fi
    done
    echo
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
