#!/bin/bash
# Flatcar Container Linux Installation for Raspberry Pi 4
# Based on official documentation: https://www.flatcar.org/docs/latest/installing/bare-metal/raspberry-pi/

set -euo pipefail

# Configuration
FLATCAR_VERSION="${FLATCAR_VERSION:-stable}"
FLATCAR_BOARD="arm64-usr"
WORK_DIR="$(pwd)/flatcar-pi-deploy"

# Node configuration
declare -A NODES=(
    ["swarm-manager-1"]="manager|192.168.99.101"
    ["swarm-manager-2"]="manager|192.168.99.102"
    ["swarm-manager-3"]="manager|192.168.99.103"
    ["swarm-worker-1"]="worker|192.168.99.111"
)

PRIMARY_MANAGER_IP="192.168.99.101"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-$(cat ~/.ssh/id_rsa.pub)}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_step() { echo -e "\n${GREEN}===${NC} $1 ${GREEN}===${NC}"; }

# Setup work directory
setup_workdir() {
    print_step "Setting Up Work Directory"
    mkdir -p "$WORK_DIR"/{ignition,bootstrap}
    cd "$WORK_DIR"
    print_info "Work directory: $WORK_DIR"
}

# Download flatcar-install script
download_flatcar_install() {
    print_step "Downloading flatcar-install Script"
    
    if [ ! -f "./flatcar-install" ]; then
        wget https://raw.githubusercontent.com/flatcar/init/flatcar-master/bin/flatcar-install
        chmod +x flatcar-install
        print_info "✓ Downloaded flatcar-install"
    else
        print_info "✓ flatcar-install already exists"
    fi
}

# Download swarm bootstrap script
setup_bootstrap_script() {
    print_step "Setting Up Bootstrap Script"
    
    # Try multiple locations
    local bootstrap_source=""
    if [ -f "../swarm-bootstrap.sh" ]; then
        bootstrap_source="../swarm-bootstrap.sh"
    elif [ -f "./swarm-bootstrap.sh" ]; then
        bootstrap_source="./swarm-bootstrap.sh"
    elif [ -f "$(dirname "$0")/swarm-bootstrap.sh" ]; then
        bootstrap_source="$(dirname "$0")/swarm-bootstrap.sh"
    fi
    
    if [ -n "$bootstrap_source" ]; then
        cp "$bootstrap_source" ./bootstrap/swarm-bootstrap.sh
        print_info "✓ Copied swarm-bootstrap.sh"
    else
        print_error "swarm-bootstrap.sh not found"
        print_error "Checked: ../, ./, script directory"
        exit 1
    fi
}

# Generate Butane config for a node
generate_node_config() {
    local hostname="$1"
    local role="$2"
    local ip="$3"
    local output_file="$4"
    
    print_info "Generating config for $hostname ($role) at $ip"
    
    cat > "$output_file" << 'EOFMAIN'
{
  "ignition": { "version": "2.3.0" },
  "networkd": {
    "units": [{
      "name": "00-static.network",
      "contents": "[Match]\nName=en*\n\n[Network]\nDHCP=no\nAddress=IP_PLACEHOLDER/24\nGateway=192.168.99.1\nDNS=1.1.1.1\nDNS=9.9.9.9\n"
    }]
  },
  "passwd": {
    "users": [{
      "name": "core",
      "sshAuthorizedKeys": ["SSH_KEY_PLACEHOLDER"],
      "groups": ["sudo"]
    }]
  },
  "storage": {
    "files": [{
      "filesystem": "root",
      "path": "/etc/hostname",
      "mode": 420,
      "contents": { "source": "data:,HOSTNAME_PLACEHOLDER" }
    }, {
      "filesystem": "root",
      "path": "/etc/environment",
      "mode": 420,
      "contents": {
        "source": "data:,SWARM_NODE_ROLE%3DROLE_PLACEHOLDER%0ASWARM_PRIMARY_MANAGER_IP%3D192.168.99.101%0A"
      }
    }, {
      "filesystem": "OEM",
      "path": "/grub.cfg",
      "mode": 420,
      "append": true,
      "contents": {
        "source": "data:,set%20linux_console%3D%22console%3DttyAMA0%2C115200n8%20console%3Dtty1%22%0Aset%20linux_append%3D%22flatcar.autologin%20usbcore.autosuspend%3D-1%22%0A"
      }
    }]
  }
}
EOFMAIN

    # Replace placeholders
    sed -i "s|IP_PLACEHOLDER|$ip|g" "$output_file"
    sed -i "s|SSH_KEY_PLACEHOLDER|$SSH_PUBLIC_KEY|g" "$output_file"
    sed -i "s|HOSTNAME_PLACEHOLDER|$hostname|g" "$output_file"
    sed -i "s|ROLE_PLACEHOLDER|$role|g" "$output_file"
}

# Generate all configs
generate_configs() {
    print_step "Generating Ignition Configurations"
    
    for hostname in "${!NODES[@]}"; do
        IFS='|' read -r role ip <<< "${NODES[$hostname]}"
        
        local ignition_file="./ignition/${hostname}.ign"
        
        generate_node_config "$hostname" "$role" "$ip" "$ignition_file"
        
        if [ -s "$ignition_file" ]; then
            print_info "✓ Generated: ${hostname}.ign"
        else
            print_error "Failed to generate $hostname config"
            exit 1
        fi
    done
}

# Install Flatcar to device using flatcar-install
install_flatcar_to_device() {
    local device="$1"
    local ignition_file="$2"
    local hostname="$3"
    
    print_step "Installing Flatcar to $device for $hostname"
    
    if [ ! -b "$device" ]; then
        print_error "Device $device not found"
        return 1
    fi
    
    # Unmount any mounted partitions
    sudo umount ${device}* 2>/dev/null || true
    
    print_info "Running flatcar-install (this will take 5-10 minutes)..."
    sudo ./flatcar-install \
        -d "$device" \
        -C "$FLATCAR_VERSION" \
        -B "$FLATCAR_BOARD" \
        -o '' \
        -i "$ignition_file"
    
    print_info "✓ Flatcar installed to $device"
}

# Install UEFI firmware to EFI partition
install_uefi_firmware() {
    local device="$1"
    local hostname="$2"
    
    print_step "Installing RPi4 UEFI Firmware for $hostname"
    
    # Wait for partitions to be recognized
    sleep 3
    sudo partprobe "$device"
    sleep 2
    
    # Find EFI partition
    local efi_partition=$(lsblk "$device" -oLABEL,PATH | awk '$1 == "EFI-SYSTEM" {print $2}')
    
    if [ -z "$efi_partition" ]; then
        print_error "EFI partition not found on $device"
        return 1
    fi
    
    print_info "EFI partition: $efi_partition"
    
    # Mount EFI partition
    local mount_point="/tmp/efi_${hostname}"
    sudo mkdir -p "$mount_point"
    sudo mount "$efi_partition" "$mount_point"
    
    # Download latest UEFI firmware
    print_info "Downloading latest RPi4 UEFI firmware..."
    local version=$(curl --silent "https://api.github.com/repos/pftf/RPi4/releases/latest" | jq -r .tag_name)
    print_info "Latest version: $version"
    
    local firmware_zip="RPi4_UEFI_Firmware_${version}.zip"
    wget -q "https://github.com/pftf/RPi4/releases/download/${version}/${firmware_zip}" -O "/tmp/${firmware_zip}"
    
    # Extract firmware to EFI partition
    print_info "Extracting firmware..."
    sudo unzip -q -o "/tmp/${firmware_zip}" -d "$mount_point"
    
    # Cleanup
    rm "/tmp/${firmware_zip}"
    
    # Unmount
    sudo umount "$mount_point"
    sudo rmdir "$mount_point"
    
    print_info "✓ UEFI firmware installed"
}

# Interactive flash process
flash_sd_cards() {
    print_step "SD Card Flashing Process"
    
    echo ""
    echo "This will flash Flatcar + UEFI firmware to each SD card."
    echo "You will be prompted to insert each card."
    echo ""
    
    for hostname in "${!NODES[@]}"; do
        IFS='|' read -r role ip <<< "${NODES[$hostname]}"
        
        echo ""
        print_info "=== Next: $hostname ($role - $ip) ==="
        echo ""
        echo "Insert SD card for $hostname and press Enter..."
        read
        
        # Detect device
        echo ""
        echo "Available devices:"
        lsblk -d -o NAME,SIZE,TYPE | grep disk
        echo ""
        echo "Enter device name (e.g., sdb, mmcblk0): "
        read device_name
        
        local device="/dev/${device_name}"
        
        if [ ! -b "$device" ]; then
            print_error "Device $device not found. Skipping..."
            continue
        fi
        
        # Confirm
        echo ""
        print_warn "WARNING: All data on $device will be erased!"
        echo "Device: $device"
        echo "Node: $hostname"
        echo "Continue? (yes/no): "
        read confirm
        
        if [ "$confirm" != "yes" ]; then
            print_info "Skipped $hostname"
            continue
        fi
        
        # Install Flatcar
        install_flatcar_to_device "$device" "./ignition/${hostname}.ign" "$hostname"
        
        # Install UEFI firmware
        install_uefi_firmware "$device" "$hostname"
        
        # Final sync
        sync
        sleep 2
        
        print_info "✓ $hostname ready!"
        echo ""
        echo "You can now remove the SD card."
        echo "Press Enter to continue to next node..."
        read
    done
    
    print_step "All SD Cards Flashed!"
    echo ""
    echo "Boot sequence:"
    echo "  1. Insert SD card into Raspberry Pi"
    echo "  2. Connect Ethernet cable"
    echo "  3. Power on"
    echo "  4. Wait 2-3 minutes for boot"
    echo "  5. Node should appear at its assigned IP"
    echo ""
}

# Check prerequisites
check_prerequisites() {
    print_step "Checking Prerequisites"
    
    local missing=0
    
    for tool in wget curl jq unzip lsblk; do
        if ! command -v "$tool" &> /dev/null; then
            print_error "Required tool '$tool' not found"
            missing=1
        else
            print_info "✓ Found $tool"
        fi
    done
    
    if [ $missing -eq 1 ]; then
        print_error "Missing required tools. Install them first."
        exit 1
    fi
    
    if [ ! -f "../swarm-bootstrap.sh" ] && [ ! -f "./swarm-bootstrap.sh" ] && [ ! -f "$(dirname "$0")/swarm-bootstrap.sh" ]; then
        print_error "swarm-bootstrap.sh not found"
        print_error "Place it in scripts/ directory alongside this script"
        exit 1
    fi
    
    print_info "✓ All prerequisites met"
}

# Main execution
main() {
    echo "=== Flatcar Container Linux - Raspberry Pi 4 Installation ==="
    echo ""
    echo "This script will:"
    echo "  1. Generate Ignition configs for all nodes"
    echo "  2. Install Flatcar to SD cards using flatcar-install"
    echo "  3. Install RPi4 UEFI firmware to each card"
    echo "  4. Configure static IPs and Docker Swarm"
    echo ""
    echo "Nodes:"
    for hostname in "${!NODES[@]}"; do
        IFS='|' read -r role ip <<< "${NODES[$hostname]}"
        echo "  - $hostname: $role at $ip"
    done
    echo ""
    echo "Continue? (yes/no): "
    read confirm
    
    if [ "$confirm" != "yes" ]; then
        echo "Aborted."
        exit 0
    fi
    
    check_prerequisites
    setup_workdir
    download_flatcar_install
    generate_configs
    flash_sd_cards
    
    print_step "Deployment Complete!"
    echo ""
    echo "Next steps:"
    echo "  1. Boot all Raspberry Pis"
    echo "  2. Wait 3-5 minutes for cluster formation"
    echo "  3. SSH to primary manager: ssh core@192.168.99.101"
    echo "  4. Check cluster status: docker node ls"
    echo ""
}

main "$@"
