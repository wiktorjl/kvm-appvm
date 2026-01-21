# KVM-APPVM

## About

This allows you to easily launch disposable VMs using KVM. Such VMs are ephemeral and reset to a clean state on each boot. They are great for tasks you do not want to perform on your host, like opening a PDF file from an unknown source.

In addition, you can launch something I call "App VM". I have borrowed the concept from Qubes OS. It is essentially a disposable VM, except that we attach a persistent disk drive that is bind mounted to /usr/local and /home. This type of VM is intended for longer running projects. While the root filesystem resets on each power cycle, your home and /usr/local remain the same.

Additional features:
1. Sets the hostname to match the VM name
2. Connects to the VM via RDP

## Templates

Both types of VMs are created from a template you provide. For now, the template is assumed to be a Debian 12-13 installation. To update the template, launch it with `appvm update-template`, run your updates, then shut down. 

## Installation

```bash
sudo ./install.sh
```

On first run, `appvm` creates a config file at `~/.config/appvm/config` with default values. Review and adjust paths as needed.
