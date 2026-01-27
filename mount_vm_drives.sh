#!/bin/bash
# mount_vm_drives.sh - Mount VM home directories via SSHFS
#
# Discovers running appvm-managed VMs and mounts their /home/<user>
# directories locally for easy file access.

set -e

# Configuration defaults
DEFAULT_MOUNT_DIR="$HOME/mounts"
DEFAULT_NET_PREFIX="192.168.122."
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/appvm"
LOG_FILE="$LOG_DIR/appvm.log"
CONFIG_FILES=("/etc/appvm/config" "$HOME/.config/appvm/config")

# Script state
UNMOUNT_MODE=false
ALL_VMS_MODE=false
VM_NAMES=()

# Read value from INI config files
# Usage: read_config <section> <key> <default>
# Reads from both system and user config, later overrides earlier
read_config() {
    local section="$1"
    local key="$2"
    local default="$3"
    local value=""

    for config_file in "${CONFIG_FILES[@]}"; do
        if [[ -f "$config_file" ]]; then
            local file_value
            file_value=$(awk -F '=' -v section="$section" -v key="$key" '
                /^\[.*\]$/ { current_section = substr($0, 2, length($0)-2) }
                current_section == section && $1 ~ "^[[:space:]]*"key"[[:space:]]*$" {
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
                    print $2
                    exit
                }
            ' "$config_file")
            if [[ -n "$file_value" ]]; then
                value="$file_value"
            fi
        fi
    done

    if [[ -n "$value" ]]; then
        # Expand ~ in paths
        echo "${value/#\~/$HOME}"
    else
        echo "$default"
    fi
}

# Log action to log file
log_action() {
    local action="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Ensure log directory exists
    mkdir -p "$LOG_DIR" 2>/dev/null || true

    echo "[$timestamp] [SSHFS] [$action] $message" >> "$LOG_FILE" 2>/dev/null || true
}

# Print status message
status() {
    echo "[*] $1"
}

# Print success message
success() {
    echo "[+] $1"
}

# Print error message
error() {
    echo "[-] $1" >&2
}

# Show help
show_help() {
    cat <<'EOF'
Usage: mount_vm_drives.sh [OPTIONS] [VM_NAME...]

Mount VM home directories via SSHFS for easy file access.

Arguments:
  VM_NAME          Specific VM(s) to mount/unmount (optional, defaults to all running VMs)

Options:
  -a, --all        Mount/unmount all running VMs (not just appvm-managed)
  -u, --unmount    Unmount VM directories instead of mounting
  -h, --help       Show this help message

Examples:
  mount_vm_drives.sh                    # Mount all running VMs
  mount_vm_drives.sh disp-vm-firefox    # Mount only disp-vm-firefox
  mount_vm_drives.sh -u                 # Unmount all mounted VMs
  mount_vm_drives.sh -u work-sys-dev    # Unmount only work-sys-dev
  mount_vm_drives.sh -a                 # Mount all running VMs (any name)

Configuration:
  Add to /etc/appvm/config or ~/.config/appvm/config:

  [sshfs]
  mount_dir = ~/mounts                  # Local mount directory
  # remote_user = user                  # Defaults to rdp.username

EOF
}

# Get list of running VMs
# Args: all_mode (optional, default false) - if true, return all VMs, not just appvm-managed
get_running_vms() {
    local all_mode="${1:-false}"
    if [[ "$all_mode" == "true" ]]; then
        # Return all running VMs
        sudo virsh list --state-running --name 2>/dev/null | grep -v '^$' || true
    else
        # Return only appvm-managed VMs
        sudo virsh list --state-running --name 2>/dev/null | grep -E '^(disp-vm-|work-sys-)' || true
    fi
}

# Check if VM exists
vm_exists() {
    local vm="$1"
    sudo virsh dominfo "$vm" &>/dev/null
}

# Check if VM is running
vm_is_running() {
    local vm="$1"
    local state
    state=$(sudo virsh domstate "$vm" 2>/dev/null)
    [[ "$state" == "running" ]]
}

# Get VM IP address via qemu-guest-agent
get_vm_ip() {
    local vm="$1"
    local net_prefix="$2"
    local output

    output=$(sudo virsh domifaddr "$vm" --source agent 2>/dev/null) || return 1

    # Parse IP from output (format: "vnet0 52:54:00:xx:xx:xx ipv4 192.168.122.x/24")
    echo "$output" | grep ipv4 | while read -r line; do
        for part in $line; do
            if [[ "$part" == */* ]]; then
                local ip="${part%/*}"
                if [[ "$ip" == "$net_prefix"* ]]; then
                    echo "$ip"
                    return 0
                fi
            fi
        done
    done
}

# Mount a single VM
mount_vm() {
    local vm="$1"
    local mount_dir="$2"
    local remote_user="$3"
    local net_prefix="$4"

    # Get VM IP
    local ip
    ip=$(get_vm_ip "$vm" "$net_prefix")
    if [[ -z "$ip" ]]; then
        error "Failed to get IP for $vm (ensure qemu-guest-agent is running)"
        log_action "MOUNT_FAIL" "$vm: could not get IP"
        return 1
    fi

    local mount_point="$mount_dir/$vm"

    # Check if already mounted
    if mountpoint -q "$mount_point" 2>/dev/null; then
        status "$vm already mounted at $mount_point"
        return 0
    fi

    # Create mount directory if needed
    mkdir -p "$mount_point"

    status "Mounting $vm (IP: $ip)..."
    log_action "MOUNT" "command: sshfs ${remote_user}@${ip}:/home/${remote_user} $mount_point"

    if sshfs "${remote_user}@${ip}:/home/${remote_user}" "$mount_point" \
        -o reconnect,ServerAliveInterval=15 2>/dev/null; then
        success "Mounted $vm at $mount_point"
        log_action "MOUNT_OK" "$vm mounted at $mount_point"
        return 0
    else
        error "Failed to mount $vm: sshfs connection failed"
        log_action "MOUNT_FAIL" "$vm: sshfs connection failed"
        # Remove empty mount directory on failure
        rmdir "$mount_point" 2>/dev/null || true
        return 1
    fi
}

# Unmount a single VM
unmount_vm() {
    local vm="$1"
    local mount_dir="$2"

    local mount_point="$mount_dir/$vm"

    # Check if mounted
    if ! mountpoint -q "$mount_point" 2>/dev/null; then
        status "$vm is not mounted"
        return 0
    fi

    status "Unmounting $vm..."
    log_action "UNMOUNT" "command: fusermount -u $mount_point"

    if fusermount -u "$mount_point" 2>/dev/null; then
        success "Unmounted $vm"
        log_action "UNMOUNT_OK" "$vm"
        # Remove empty mount directory
        rmdir "$mount_point" 2>/dev/null || true
        return 0
    else
        error "Failed to unmount $vm: fusermount failed"
        log_action "UNMOUNT_FAIL" "$vm: fusermount failed"
        return 1
    fi
}

# Find all SSHFS mounts under mount_dir
# Args: mount_dir, all_mode (optional, default false)
find_mounted_vms() {
    local mount_dir="$1"
    local all_mode="${2:-false}"

    if [[ ! -d "$mount_dir" ]]; then
        return
    fi

    for dir in "$mount_dir"/*; do
        if [[ -d "$dir" ]] && mountpoint -q "$dir" 2>/dev/null; then
            local name
            name=$(basename "$dir")
            if [[ "$all_mode" == "true" ]]; then
                echo "$name"
            elif [[ "$name" == disp-vm-* ]] || [[ "$name" == work-sys-* ]]; then
                echo "$name"
            fi
        fi
    done
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -a|--all)
                ALL_VMS_MODE=true
                shift
                ;;
            -u|--unmount)
                UNMOUNT_MODE=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -*)
                error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                VM_NAMES+=("$1")
                shift
                ;;
        esac
    done
}

# Main function
main() {
    parse_args "$@"

    # Load configuration
    local mount_dir net_prefix remote_user
    mount_dir=$(read_config "sshfs" "mount_dir" "$DEFAULT_MOUNT_DIR")
    net_prefix=$(read_config "network" "prefix" "$DEFAULT_NET_PREFIX")
    remote_user=$(read_config "sshfs" "remote_user" "")

    # Fall back to rdp.username if sshfs.remote_user not set
    if [[ -z "$remote_user" ]]; then
        remote_user=$(read_config "rdp" "username" "$USER")
    fi

    log_action "START" "mount_dir=$mount_dir remote_user=$remote_user unmount=$UNMOUNT_MODE all_vms=$ALL_VMS_MODE vms=${VM_NAMES[*]:-all}"

    if $UNMOUNT_MODE; then
        # Unmount mode
        local vms_to_unmount=()

        if [[ ${#VM_NAMES[@]} -gt 0 ]]; then
            # Unmount specific VMs
            vms_to_unmount=("${VM_NAMES[@]}")
        else
            # Find all mounted VMs
            status "Finding SSHFS mounts in $mount_dir..."
            while IFS= read -r vm; do
                [[ -n "$vm" ]] && vms_to_unmount+=("$vm")
            done < <(find_mounted_vms "$mount_dir" "$ALL_VMS_MODE")
        fi

        if [[ ${#vms_to_unmount[@]} -eq 0 ]]; then
            status "No mounted VMs found"
            exit 0
        fi

        local failed=0
        for vm in "${vms_to_unmount[@]}"; do
            unmount_vm "$vm" "$mount_dir" || ((failed++))
        done

        if [[ $failed -gt 0 ]]; then
            error "$failed unmount(s) failed"
            exit 1
        fi
    else
        # Mount mode
        local vms_to_mount=()

        if [[ ${#VM_NAMES[@]} -gt 0 ]]; then
            # Mount specific VMs (validate they exist and are running)
            for vm in "${VM_NAMES[@]}"; do
                if ! vm_exists "$vm"; then
                    error "VM '$vm' does not exist"
                    continue
                fi
                if ! vm_is_running "$vm"; then
                    error "VM '$vm' is not running"
                    continue
                fi
                vms_to_mount+=("$vm")
            done
        else
            # Discover running VMs
            status "Discovering running VMs..."
            while IFS= read -r vm; do
                [[ -n "$vm" ]] && vms_to_mount+=("$vm")
            done < <(get_running_vms "$ALL_VMS_MODE")
        fi

        if [[ ${#vms_to_mount[@]} -eq 0 ]]; then
            if [[ "$ALL_VMS_MODE" == "true" ]]; then
                status "No running VMs found"
            else
                status "No managed VMs to mount"
            fi
            exit 0
        fi

        if [[ "$ALL_VMS_MODE" == "true" ]]; then
            status "Found ${#vms_to_mount[@]} running VM(s)"
        else
            status "Found ${#vms_to_mount[@]} managed VM(s)"
        fi

        # Create mount directory if needed
        mkdir -p "$mount_dir"

        local failed=0
        for vm in "${vms_to_mount[@]}"; do
            mount_vm "$vm" "$mount_dir" "$remote_user" "$net_prefix" || ((failed++))
        done

        if [[ $failed -gt 0 ]]; then
            error "$failed mount(s) failed"
            exit 1
        fi
    fi

    log_action "DONE" "operation completed"
}

main "$@"
