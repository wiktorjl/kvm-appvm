#!/usr/bin/env python3
"""Logging module for kvm-appvm.

Prefers /var/log/kvm-appvm/ (writable when running as root - qemu-hook,
guest-init). Falls back to $XDG_STATE_HOME/appvm/ (default
~/.local/state/appvm/) for the non-root CLI case, matching
mount_vm_drives.sh. If neither is writable the entry is silently
dropped - we never spam stderr.
"""

import os
from datetime import datetime
from pathlib import Path

SYSTEM_LOG_DIR = Path("/var/log/kvm-appvm")
USER_LOG_DIR = Path(
    os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local" / "state"))
) / "appvm"

LOG_FILES = {
    "appvm": "appvm.log",
    "qemu-hook": "qemu-hook.log",
    "guest-init": "guest-init.log",
}

_active_log_dir = None


def _resolve_log_dir():
    """Return the log dir to use, or None if no dir is writable."""
    global _active_log_dir
    if _active_log_dir is not None:
        return _active_log_dir

    if SYSTEM_LOG_DIR.exists() and os.access(SYSTEM_LOG_DIR, os.W_OK):
        _active_log_dir = SYSTEM_LOG_DIR
        return _active_log_dir

    try:
        USER_LOG_DIR.mkdir(parents=True, exist_ok=True)
    except OSError:
        return None

    if os.access(USER_LOG_DIR, os.W_OK):
        _active_log_dir = USER_LOG_DIR
        return _active_log_dir

    return None


def log(component: str, action: str, command: str = None, message: str = None):
    """Log an action with timestamp.

    Args:
        component: One of 'appvm', 'qemu-hook', 'guest-init'
        action: The action being performed (e.g., 'CREATE', 'START')
        command: Optional command that was executed
        message: Optional additional message
    """
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    log_entry = f"[{timestamp}] [{action}]"
    if command:
        log_entry += f" command: {command}"
    if message:
        log_entry += f" {message}"
    log_entry += "\n"

    log_dir = _resolve_log_dir()
    if log_dir is None:
        return

    log_file = log_dir / LOG_FILES.get(component, "appvm.log")
    try:
        with open(log_file, "a") as f:
            f.write(log_entry)
    except OSError:
        pass


def log_command(component: str, action: str, cmd: list):
    """Log a command that will be executed.

    Args:
        component: One of 'appvm', 'qemu-hook', 'guest-init'
        action: The action being performed
        cmd: Command as a list of arguments
    """
    command_str = " ".join(str(arg) for arg in cmd)
    log(component, action, command=command_str)
