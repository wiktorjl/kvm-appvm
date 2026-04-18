# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

kvm-appvm manages ephemeral and semi-ephemeral virtual machines using KVM/QEMU/libvirt, inspired by Qubes OS. The project provides scripts for creating disposable VMs (fully ephemeral) and work VMs (persistent /home and /usr/local with ephemeral root).

## Architecture

### VM Types

**Disposable VM (`disp-vm-<name>`)**
- Fully ephemeral - root filesystem resets on every start
- Uses template VM (template-root.qcow2) as backing store
- QEMU hook responds to "prepare" action to recreate overlay disk

**Work VM (`work-sys-<name>` + `work-priv-<name>`)**
- Ephemeral root (same as Disposable)
- Persistent private disk mounted at /rw containing:
  - /rw/home → bind mounted to /home
  - /rw/usrlocal → bind mounted to /usr/local
- First-start initialization creates user home directories and /usr/local structure
- Subsequent starts preserve /home and /usr/local while resetting root

### Disk Layout

| VM Type | System Disk | Private Disk |
|---------|-------------|--------------|
| Disposable | disp-vm-\<name\>.qcow2 (overlay) | None |
| Work | work-sys-\<name\>.qcow2 (overlay) | work-priv-\<name\>.qcow2 |

All overlays use template-root.qcow2 as backing store.

### Key Technologies

- **virsh** - VM lifecycle management (clone from template, start/stop)
- **QEMU hooks** - Automatic overlay disk creation on VM start
- **qcow2** - Disk format with backing store support for copy-on-write overlays

## Implementation Details

### Languages

- **Bash** - Simple operations (VM lifecycle, hooks)
- **Python** - Complex logic where needed

### CLI

Simple interface: `appvm <command> [args]`

**Implemented commands:**
- `appvm create disp <name> [-s|--start] [-c|--connect] [--ssh]` - Create disposable VM. `-s` also starts it; `-c` additionally waits for the guest agent and opens RDP (implies `-s`); `--ssh` does the same but opens an SSH shell instead. `-c` and `--ssh` are mutually exclusive.
- `appvm create work <name> [-s|--start] [-c|--connect] [--ssh]` - Create work VM with private disk (same flags as above)
- `appvm start <name>` - Start a VM
- `appvm stop <name>` - Stop a VM (graceful shutdown)
- `appvm connect <name>` - Connect to VM via RDP. Auto-starts the VM if it isn't running and polls the guest agent for an IP (up to `network.connect_timeout`, default 60s) before launching Remmina.
- `appvm ssh <name>` - SSH into VM. Same start/wait behavior as `connect`, then `execvp`s ssh so the shell attaches to the current terminal. Because appvm root filesystems reset on every boot the VM's SSH host keys change each start, so `ssh` is invoked with `-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR` to avoid MITM warnings. Username is resolved as `[ssh].user` → `[sshfs].remote_user` → `[rdp].username` → `$USER`.
- `appvm destroy <name>` - Remove VM and its disks
- `appvm list` - List all appvm-managed VMs
- `appvm install-guest <qcow2>` - Install guest scripts into a template disk offline (via qemu-nbd)
- `appvm update-template` - Start template for updates (requires permission)

**Shared start-and-wait helper:** `ensure_running_with_ip(name)` starts the VM if needed and polls the guest agent for an IP. Both `connect_vm` and `ssh_vm` call it.

**Short-name resolution:** `start`, `stop`, `connect`, `ssh`, and `destroy` accept either the full libvirt name (`disp-vm-foo`, `work-sys-foo`) or the bare short name (`foo`). `resolve_vm_name()` looks up both prefixes: one match is used, two matches are an ambiguity error (user must give the full name), no matches is a not-found error. `create` still takes the `disp|work` type explicitly.

**Standalone scripts:**
- `mount_vm_drives.sh [VM_NAME...]` - Mount VM home directories via SSHFS
- `mount_vm_drives.sh -u [VM_NAME...]` - Unmount VM directories
- `mount_vm_drives.sh -a` - Mount all running VMs (not just appvm-managed)

**Configuration:**
Config files (INI format, later files override earlier):
1. `/etc/appvm/config` - System-wide (used by CLI, QEMU hook, and guest init)
2. `~/.config/appvm/config` - User-specific overrides

See `config/appvm.conf.example` for all options. Key sections:

```ini
[paths]
template_disk = /VM/kvm/template-root.qcow2  # Template qcow2 backing store
vm_disk_dir = /VM/kvm                         # Directory for VM disks
template_vm = template-root                   # Libvirt template VM name

[vm]
private_disk_size = 20G                       # Size of work VM private disks
private_disk_label = appvm-private            # Filesystem label for private disks

[rdp]
username = seed
# password = optional

[network]
prefix = 192.168.122.                         # VM network prefix for IP detection
connect_timeout = 60                          # Seconds to wait for guest agent on connect

[guest]
min_uid = 1000                                # Minimum UID for home directory creation
home_base = /home                             # Home directory base path

[sshfs]
mount_dir = /mnt/vm                            # Local mount directory for SSHFS
# remote_user = seed                          # Defaults to rdp.username

[ssh]
# user = seed                                 # Optional; falls back to sshfs.remote_user, rdp.username, $USER
```

Keep it minimal - don't over-engineer.

### Host-Side Components

**Template disk** - Default location `/VM/kvm/template-root.qcow2` (configurable via `paths.template_disk`). This is a working template - DO NOT modify or damage it. Always create overlays that use it as a backing store. If modification is absolutely necessary, ask the user for explicit permission first.

**QEMU hooks** - Symlink `/etc/libvirt/hooks/qemu` to this project's hook script. The hook:
- Creates overlay disk on VM start (using template as backing store)
- Sets hostname by writing `/etc/hostname` directly to the overlay before boot (via qemu-nbd loop-mount)

**VM identity** - Two mechanisms expose the VM name to the guest:
1. **SMBIOS product** - `appvm` injects `<sysinfo type="smbios">` with `product=<vm-name>` into the cloned XML and sets `<os><smbios mode="sysinfo"/>`. Guest can read it via `/sys/class/dmi/id/product_name`.
2. **`/etc/hostname`** - Written by the QEMU hook (as above) so the VM boots with its libvirt name as hostname.
On clone, `appvm` also strips UUID and interface MAC addresses so libvirt regenerates them.

**VM IP discovery** - `appvm connect` and `mount_vm_drives.sh` both use `virsh domifaddr --source agent`, which requires `qemu-guest-agent` running inside the VM. Only addresses matching `network.prefix` are returned.

**Template management** - Templates are hand-crafted. A separate script can call into a running template VM to trigger package updates.

### Guest-Side Components

**Work VM initialization script** - Installed in template at `/usr/local/bin/`. Runs early in boot (systemd unit with `Before=systemd-user-sessions.service`).

Cold start detection: if `/rw/home/` is empty, assume first boot and:
1. Create home directories from /etc/passwd using skel
2. Populate /usr/local structure

The script always:
1. Mount private disk (detected by filesystem label `appvm-private`)
2. Bind mount /rw/home → /home
3. Bind mount /rw/usrlocal → /usr/local
4. Preserve the original template dirs as read-only bind mounts at `/template/home` and `/template/usrlocal`, so the guest can still see the template copies after the overlays are in place.

**Cold-start behavior toggles** (flag files inside the template):
- `/etc/appvm-skel-only` - populate new home dirs from `/etc/skel` only, skipping the template's own user home contents
- `/etc/appvm-fresh-usrlocal` - create a fresh empty `/usr/local` skeleton instead of copying the template's `/usr/local`

### Private Disk Detection

Use filesystem label `appvm-private` (configurable via `vm.private_disk_label`) on the private qcow2 disk. The guest init script finds it via label rather than relying on device ordering.

### Logging

Log every action along with the full command executed. This applies to both host-side scripts (CLI, QEMU hooks) and guest-side initialization.

Primary log directory: `/var/log/kvm-appvm/`
- `appvm.log` - CLI operations
- `qemu-hook.log` - QEMU hook invocations
- `guest-init.log` - Guest-side initialization (inside VMs)

`lib/logger.py` picks the log dir adaptively: it writes to `/var/log/kvm-appvm/` when writable (root-run qemu-hook and guest-init), and otherwise falls back silently to `$XDG_STATE_HOME/appvm/` (default `~/.local/state/appvm/`) so the unprivileged `appvm` CLI doesn't need sudo. If neither is writable, entries are dropped — the logger never prints to stderr. `mount_vm_drives.sh` (bash) always uses the per-user path.

## File Structure

```
kvm-appvm/
├── CLAUDE.md                    # Project documentation
├── README.md                    # User-facing documentation
├── appvm                        # Main CLI (Python, executable)
├── mount_vm_drives.sh           # SSHFS mount helper (Bash)
├── install.sh                   # Host installation script
├── config/
│   └── appvm.conf.example       # Example configuration file
├── lib/
│   ├── __init__.py
│   └── logger.py                # Shared logging module
├── hooks/
│   └── qemu                     # QEMU hook script (Bash)
└── guest/
    ├── appvm-init               # Guest init script (Bash)
    └── appvm-init.service       # Systemd unit file
```

## Installation

**Host setup:**
```bash
sudo ./install.sh
```

**Guest setup (inside template VM):**
```bash
sudo cp guest/appvm-init /usr/local/bin/
sudo cp guest/appvm-init.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable appvm-init.service
```
