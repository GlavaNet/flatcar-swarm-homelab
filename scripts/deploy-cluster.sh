#!/bin/bash
# Complete Flatcar Docker Swarm Cluster Deployment Script
# This script automates the entire setup process

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
FLATCAR_VERSION="stable"
FLATCAR_ARCH="arm64-usr"
FLATCAR_IMAGE_URL="https://${FLATCAR_VERSION}.release.flatcar-linux.net/${FLATCAR_ARCH}/current/flatcar_production_image.bin.bz2"
WORK_DIR="$(pwd)/flatcar-swarm-deploy"

# Node configuration
declare -A NODES=(
    ["swarm-manager-1"]="manager|192.168.1.101"
    ["swarm-manager-2"]="manager|192.168.1.102"
    ["swarm-manager-3"]="manager|192.168.1.103"
    ["swarm-worker-1"]="worker|192.168.1.111"
)

# Primary manager IP (must match one of the above)
PRIMARY_MANAGER_IP="192.168.1.101"

# Print functions
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_step() {
    echo -e "\n${GREEN}===${NC} $1 ${GREEN}===${NC}\n"
}

# Check prerequisites
check_prerequisites() {
    print_step "Checking Prerequisites"
    
    local missing=0
    
    # Check for required tools
    for tool in wget bunzip2 dd sync; do
        if ! command -v "$tool" &> /dev/null; then
            print_error "Required tool '$tool' not found"
            missing=1
        else
            print_info "✓ Found $tool"
        fi
    done
    
    # Check for ct (Container Linux Config Transpiler)
    if ! command -v ct &> /dev/null; then
        print_warn "Config transpiler 'ct' not found. Installing..."
        install_ct
    else
        print_info "✓ Found ct"
    fi
    
    if [ $missing -eq 1 ]; then
        print_error "Missing required tools. Please install them first."
        exit 1
    fi
}

# Install Container Linux Config Transpiler
install_ct() {
    local ct_version="v0.9.4"
    local ct_url="https://github.com/flatcar/container-linux-config-transpiler/releases/download/${ct_version}/ct-${ct_version}-x86_64-unknown-linux-gnu"
    
    print_info "Downloading ct ${ct_version}..."
    
    if wget -q "$ct_url" -O /tmp/ct 2>/dev/null; then
        chmod +x /tmp/ct
        sudo mv /tmp/ct /usr/local/bin/ct
        print_info "✓ Installed ct binary"
    else
        print_warn "Binary download failed, using Docker image instead"
        # Create wrapper script to use Docker image
        sudo tee /usr/local/bin/ct > /dev/null << 'EOF'
#!/bin/bash
# Wrapper script to use ct via Docker
docker run --rm -i ghcr.io/flatcar/ct:latest "$@"
EOF
        sudo chmod +x /usr/local/bin/ct
        print_info "✓ Installed ct (Docker wrapper)"
    fi
}

# Setup work directory
setup_workdir() {
    print_step "Setting Up Work Directory"
    
    mkdir -p "$WORK_DIR"/{configs,ignition,images}
    cd "$WORK_DIR"
    
    print_info "Work directory: $WORK_DIR"
}

# Generate SSH key if needed
generate_ssh_key() {
    print_step "Checking SSH Keys"
    
    if [ ! -f ~/.ssh/id_rsa.pub ]; then
        print_warn "No SSH key found. Generating one..."
        ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""
        print_info "✓ Generated SSH key"
    else
        print_info "✓ SSH key exists"
    fi
    
    SSH_PUBLIC_KEY=$(cat ~/.ssh/id_rsa.pub)
    print_info "SSH public key: ${SSH_PUBLIC_KEY:0:50}..."
}

# Download Flatcar image
download_flatcar() {
    print_step "Downloading Flatcar Container Linux"
    
    local image_file="$WORK_DIR/images/flatcar_production_image.bin"
    
    if [ -f "$image_file" ]; then
        print_info "Flatcar image already exists, skipping download"
        return
    fi
    
    print_info "Downloading from: $FLATCAR_IMAGE_URL"
    wget -c "$FLATCAR_IMAGE_URL" -O "$WORK_DIR/images/flatcar_production_image.bin.bz2"
    
    print_info "Decompressing image..."
    bunzip2 -f "$WORK_DIR/images/flatcar_production_image.bin.bz2"
    
    print_info "✓ Flatcar image ready: $image_file"
}

# Generate node configuration
generate_node_config() {
    local hostname="$1"
    local role="$2"
    local output_file="$3"
    
    print_info "Generating config for $hostname ($role)"
    
    cat > "$output_file" << EOF
variant: flatcar
version: 1.0.0

passwd:
  users:
    - name: core
      ssh_authorized_keys:
        - "$SSH_PUBLIC_KEY"
      groups:
        - sudo
        - docker

storage:
  files:
    - path: /etc/hostname
      mode: 0644
      contents:
        inline: "$hostname"
    
    - path: /opt/bin/swarm-bootstrap.sh
      mode: 0755
      contents:
        inline: |
$(cat swarm-bootstrap.sh | sed 's/^/          /')
    
    - path: /etc/environment
      mode: 0644
      contents:
        inline: |
          SWARM_NODE_ROLE=$role
          SWARM_PRIMARY_MANAGER_IP=$PRIMARY_MANAGER_IP

systemd:
  units:
    - name: docker.service
      enabled: true
      dropins:
        - name: 10-docker-opts.conf
          contents: |
            [Service]
            Environment="DOCKER_OPTS=--log-driver=json-file --log-opt max-size=10m --log-opt max-file=3"
    
    - name: swarm-bootstrap.service
      enabled: true
      contents: |
        [Unit]
        Description=Docker Swarm Automatic Bootstrap
        After=docker.service network-online.target
        Requires=docker.service
        Wants=network-online.target
        
        [Service]
        Type=oneshot
        EnvironmentFile=/etc/environment
        ExecStart=/opt/bin/swarm-bootstrap.sh
        RemainAfterExit=yes
        StandardOutput=journal
        StandardError=journal
        
        [Install]
        WantedBy=multi-user.target
    
    - name: portainer-agent.service
      enabled: true
      contents: |
        [Unit]
        Description=Portainer Agent
        After=swarm-bootstrap.service docker.service
        Requires=docker.service
        
        [Service]
        Restart=always
        RestartSec=10
        ExecStartPre=-/usr/bin/docker stop portainer_agent
        ExecStartPre=-/usr/bin/docker rm portainer_agent
        ExecStart=/usr/bin/docker run --rm --name portainer_agent \\
          -p 9001:9001 \\
          -v /var/run/docker.sock:/var/run/docker.sock \\
          -v /var/lib/docker/volumes:/var/lib/docker/volumes \\
          -v /:/host \\
          portainer/agent:latest
        ExecStop=/usr/bin/docker stop portainer_agent
        
        [Install]
        WantedBy=multi-user.target
    
    - name: update-engine.service
      mask: true
    
    - name: locksmithd.service
      mask: true
    
    - name: docker-cleanup.timer
      enabled: true
      contents: |
        [Unit]
        Description=Docker Cleanup Timer
        
        [Timer]
        OnCalendar=daily
        Persistent=true
        
        [Install]
        WantedBy=timers.target
    
    - name: docker-cleanup.service
      contents: |
        [Unit]
        Description=Docker System Cleanup
        
        [Service]
        Type=oneshot
        ExecStart=/usr/bin/docker system prune -af --volumes --filter "until=72h"
EOF
}

# Generate all configs and transpile to Ignition
generate_configs() {
    print_step "Generating Ignition Configurations"
    
    for hostname in "${!NODES[@]}"; do
        IFS='|' read -r role ip <<< "${NODES[$hostname]}"
        
        local config_file="$WORK_DIR/configs/${hostname}.yaml"
        local ignition_file="$WORK_DIR/ignition/${hostname}.ign"
        
        generate_node_config "$hostname" "$role" "$config_file"
        
        print_info "Transpiling $hostname config to Ignition..."
        ct --in-file "$config_file" --out-file "$ignition_file"
        
        if [ $? -eq 0 ]; then
            print_info "✓ Generated Ignition config: ${hostname}.ign"
        else
            print_error "Failed to transpile config for $hostname"
            exit 1
        fi
    done
}

# Flash SD card
flash_sd_card() {
    local hostname="$1"
    local device="$2"
    
    print_step "Flashing SD Card for $hostname"
    
    # Safety check
    if [[ ! "$device" =~ ^/dev/(sd[a-z]|mmcblk[0-9])$ ]]; then
        print_error "Invalid device: $device"
        return 1
    fi
    
    # Confirmation
    print_warn "About to write to $device for node $hostname"
    print_warn "ALL DATA ON $device WILL BE DESTROYED!"
    read -p "Type 'yes' to continue: " confirm
    
    if [ "$confirm" != "yes" ]; then
        print_info "Skipping $hostname"
        return 0
    fi
    
    # Unmount any mounted partitions
    print_info "Unmounting any mounted partitions..."
    sudo umount ${device}* 2>/dev/null || true
    
    # Write image
    print_info "Writing Flatcar image to $device..."
    sudo dd if="$WORK_DIR/images/flatcar_production_image.bin" \
        of="$device" \
        bs=4M \
        status=progress \
        conv=fsync
    
    sync
    sleep 2
    
    # Mount OEM partition and copy Ignition config
    print_info "Mounting OEM partition..."
    sudo mkdir -p /mnt/flatcar-oem
    
    # Find the OEM partition (usually partition 6)
    local oem_partition="${device}6"
    if [[ "$device" =~ mmcblk ]]; then
        oem_partition="${device}p6"
    fi
    
    sudo mount "$oem_partition" /mnt/flatcar-oem
    
    print_info "Copying Ignition config..."
    sudo cp "$WORK_DIR/ignition/${hostname}.ign" /mnt/flatcar-oem/config.ign
    
    print_info "Unmounting..."
    sudo umount /mnt/flatcar-oem
    
    sync
    
    print_info "✓ SD card for $hostname is ready!"
    print_warn "You can now remove the SD card and insert it into the Raspberry Pi"
}

# Interactive SD card flashing
interactive_flash() {
    print_step "Interactive SD Card Flashing"
    
    for hostname in "${!NODES[@]}"; do
        echo ""
        print_info "Ready to flash: $hostname"
        read -p "Insert SD card and press Enter (or 's' to skip, 'q' to quit): " choice
        
        case "$choice" in
            s|S)
                print_info "Skipping $hostname"
                continue
                ;;
            q|Q)
                print_info "Quitting flash process"
                return
                ;;
        esac
        
        # List available devices
        print_info "Available block devices:"
        lsblk -d -o NAME,SIZE,TYPE | grep -E "sd[a-z]|mmcblk"
        
        read -p "Enter device (e.g., /dev/sdb or /dev/mmcblk0): " device
        
        flash_sd_card "$hostname" "$device"
    done
}

# Print cluster info
print_cluster_info() {
    print_step "Cluster Information"
    
    echo "Node Configuration:"
    echo "===================="
    for hostname in "${!NODES[@]}"; do
        IFS='|' read -r role ip <<< "${NODES[$hostname]}"
        printf "%-20s | %-10s | %s\n" "$hostname" "$role" "$ip"
    done
    
    echo ""
    echo "Primary Manager: ${PRIMARY_MANAGER_IP}"
    echo ""
    echo "After booting all nodes:"
    echo "1. SSH into manager-1: ssh core@${PRIMARY_MANAGER_IP}"
    echo "2. Check cluster status: docker node ls"
    echo "3. View bootstrap logs: journalctl -u swarm-bootstrap.service -f"
    echo "4. Access Portainer: Deploy it with the script in the next step"
    echo ""
}

# Deploy Portainer
deploy_portainer_script() {
    print_step "Creating Portainer Deployment Script"
    
    cat > "$WORK_DIR/deploy-portainer.sh" << 'EOF'
#!/bin/bash
# Deploy Portainer to the Swarm cluster
# Run this on a manager node

set -euo pipefail

echo "Creating Portainer volume..."
docker volume create portainer_data

echo "Deploying Portainer..."
docker service create \
  --name portainer \
  --publish 9443:9443 \
  --publish 8000:8000 \
  --constraint 'node.role == manager' \
  --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock \
  --mount type=volume,src=portainer_data,dst=/data \
  --replicas 1 \
  portainer/portainer-ce:latest

echo ""
echo "Portainer deployed! Access it at:"
echo "https://$(hostname -I | awk '{print $1}'):9443"
echo ""
echo "Wait 30 seconds for it to start, then create your admin account"
EOF
    
    chmod +x "$WORK_DIR/deploy-portainer.sh"
    print_info "✓ Created deploy-portainer.sh"
}

# Main execution
main() {
    print_step "Flatcar Docker Swarm Zero-Touch Deployment"
    
    echo "This script will:"
    echo "1. Download Flatcar Container Linux"
    echo "2. Generate Ignition configs for all nodes"
    echo "3. Flash SD cards for your Raspberry Pis"
    echo ""
    
    read -p "Continue? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        print_info "Cancelled"
        exit 0
    fi
    
    check_prerequisites
    setup_workdir
    generate_ssh_key
    download_flatcar
    generate_configs
    deploy_portainer_script
    
    print_cluster_info
    
    echo ""
    read -p "Ready to flash SD cards? (yes/no): " flash_confirm
    if [ "$flash_confirm" = "yes" ]; then
        interactive_flash
    else
        print_info "Skipping SD card flashing"
        print_info "You can flash cards later using the generated Ignition configs in:"
        print_info "$WORK_DIR/ignition/"
    fi
    
    print_step "Deployment Complete!"
    print_info "All configuration files are in: $WORK_DIR"
    print_info "Next steps:"
    echo "1. Insert SD cards into your Raspberry Pis"
    echo "2. Connect them to your network"
    echo "3. Power them on"
    echo "4. Wait 2-3 minutes for cluster formation"
    echo "5. SSH to manager-1: ssh core@${PRIMARY_MANAGER_IP}"
    echo "6. Run: ./deploy-portainer.sh (copy from $WORK_DIR)"
}

# Run main
main "$@"
