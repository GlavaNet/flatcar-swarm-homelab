#!/bin/bash
# Create Docker volumes backed by GlusterFS

set -e

GLUSTER_SERVER="192.168.99.101"
VOLUME_NAME="gv0"

echo "=== Creating GlusterFS-backed Docker Volumes ==="
echo ""

# Function to create a GlusterFS volume
create_gluster_volume() {
    local vol_name="$1"
    local subdir="$2"
    
    echo "Creating volume: $vol_name (subdir: $subdir)"
    
    # Create subdirectory in GlusterFS if it doesn't exist
    sudo mkdir -p "/mnt/gluster/${subdir}"
    
    # Create Docker volume using local driver with GlusterFS mount
    docker volume create \
        --driver local \
        --opt type=glusterfs \
        --opt o=addr=${GLUSTER_SERVER} \
        --opt device=:/${VOLUME_NAME}/${subdir} \
        ${vol_name}-gluster
    
    echo "✓ Created ${vol_name}-gluster"
}

# Ensure GlusterFS is mounted
echo "Mounting GlusterFS volume..."
sudo mkdir -p /mnt/gluster
sudo mount -t glusterfs ${GLUSTER_SERVER}:/${VOLUME_NAME} /mnt/gluster 2>/dev/null || \
    echo "Already mounted"

echo ""
echo "Creating service volumes..."
echo ""

# Create volumes for each service
create_gluster_volume "forgejo-data" "forgejo"
create_gluster_volume "grafana-data" "grafana"
create_gluster_volume "prometheus-data" "prometheus"
create_gluster_volume "alertmanager-data" "alertmanager"
create_gluster_volume "vaultwarden-data" "vaultwarden"
create_gluster_volume "homeassistant-config" "homeassistant"
create_gluster_volume "adguard-work" "adguard/work"
create_gluster_volume "adguard-conf" "adguard/conf"
create_gluster_volume "ntfy-cache" "ntfy/cache"
create_gluster_volume "ntfy-data" "ntfy/data"

echo ""
echo "=== Volume Creation Complete ==="
echo ""
echo "Volumes created:"
docker volume ls | grep gluster

echo ""
echo "To use these volumes, update your stack files to reference"
echo "the '-gluster' volume names (e.g., forgejo-data-gluster)"
echo ""
