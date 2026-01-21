#!/usr/bin/env python3
"""Logging module for kvm-appvm.

Provides consistent logging across all components with automatic
log directory creation and timestamped entries.
"""

import os
import sys
from datetime import datetime
from pathlib import Path

LOG_DIR = Path("/var/log/kvm-appvm")

# Log file names for different components
LOG_FILES = {
    "appvm": "appvm.log",
    "qemu-hook": "qemu-hook.log",
    "guest-init": "guest-init.log",
}


def ensure_log_dir():
    """Create log directory if it doesn't exist."""
    if not LOG_DIR.exists():
        try:
            LOG_DIR.mkdir(parents=True, mode=0o755)
        except PermissionError:
            # Fall back to stderr if we can't create the log directory
            print(f"Warning: Cannot create {LOG_DIR}, logging to stderr",
                  file=sys.stderr)
            return False
    return True


def log(component: str, action: str, command: str = None, message: str = None):
    """Log an action with timestamp.

    Args:
        component: One of 'appvm', 'qemu-hook', 'guest-init'
        action: The action being performed (e.g., 'CREATE', 'START', 'PREPARE')
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

    if ensure_log_dir():
        log_file = LOG_DIR / LOG_FILES.get(component, "appvm.log")
        try:
            with open(log_file, "a") as f:
                f.write(log_entry)
        except PermissionError:
            print(f"Warning: Cannot write to {log_file}", file=sys.stderr)
            print(log_entry, file=sys.stderr)
    else:
        print(log_entry, file=sys.stderr)


def log_command(component: str, action: str, cmd: list):
    """Log a command that will be executed.

    Args:
        component: One of 'appvm', 'qemu-hook', 'guest-init'
        action: The action being performed
        cmd: Command as a list of arguments
    """
    command_str = " ".join(str(arg) for arg in cmd)
    log(component, action, command=command_str)


# Bash helper function for use in shell scripts
BASH_LOG_FUNCTION = '''
log_action() {
    local component="$1"
    local action="$2"
    local message="$3"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_dir="/var/log/kvm-appvm"
    local log_file

    case "$component" in
        qemu-hook) log_file="$log_dir/qemu-hook.log" ;;
        guest-init) log_file="$log_dir/guest-init.log" ;;
        *) log_file="$log_dir/appvm.log" ;;
    esac

    mkdir -p "$log_dir" 2>/dev/null || true
    echo "[$timestamp] [$action] $message" >> "$log_file" 2>/dev/null || \
        echo "[$timestamp] [$action] $message" >&2
}
'''
