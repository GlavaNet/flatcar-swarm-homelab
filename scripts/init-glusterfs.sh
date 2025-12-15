#!/bin/bash
# Initialize GlusterFS cluster after deployment

set -e

MANAGER_IPS=("192.168.99.101" "192.168.99.102" "192.168.99.103")
VOLUME_NAME="gv0"
BRICK_PATH="/data/brick1/gv0"

echo "=== GlusterFS Cluster Initialization ==="
echo ""

# Wait for services to be running
echo "Waiting for GlusterFS services to start..."
sleep 30

# Get the container ID on this node
CONTAINER_ID=$(docker ps -q -f name=glusterfs_glusterfs)

if [ -z "$CONTAINER_ID" ]; then
    echo "ERROR: GlusterFS container not found on this node"
    exit 1
fi

echo "GlusterFS container: $CONTAINER_ID"
echo ""

# Probe peer nodes (skip if already connected)
echo "Step 1: Probing peer nodes..."
for ip in "${MANAGER_IPS[@]}"; do
    if [ "$ip" != "$(hostname -I | awk '{print $1}')" ]; then
        echo "  Probing $ip..."
        docker exec "$CONTAINER_ID" gluster peer probe "$ip" || echo "  Already probed or self"
    fi
done

sleep 5

# Check peer status
echo ""
echo "Step 2: Checking peer status..."
docker exec "$CONTAINER_ID" gluster peer status

echo ""
echo "Step 3: Creating distributed-replicated volume..."

# Check if volume already exists
if docker exec "$CONTAINER_ID" gluster volume info "$VOLUME_NAME" >/dev/null 2>&1; then
    echo "Volume $VOLUME_NAME already exists"
else
    # Build brick list (replica 3 across all managers)
    BRICKS=""
    for ip in "${MANAGER_IPS[@]}"; do
        BRICKS="$BRICKS ${ip}:${BRICK_PATH}"
    done
    
    echo "Creating volume with bricks:$BRICKS"
    
    # Create replicated volume (data replicated on all 3 nodes)
    docker exec "$CONTAINER_ID" gluster volume create "$VOLUME_NAME" \
        replica 3 \
        $BRICKS \
        force
    
    echo "Volume created successfully"
fi

echo ""
echo "Step 4: Starting volume..."
docker exec "$CONTAINER_ID" gluster volume start "$VOLUME_NAME" || echo "Volume already started"

echo ""
echo "Step 5: Configuring volume options..."
# Performance and reliability tuning
docker exec "$CONTAINER_ID" gluster volume set "$VOLUME_NAME" auth.allow 192.168.99.*
docker exec "$CONTAINER_ID" gluster volume set "$VOLUME_NAME" nfs.disable on
docker exec "$CONTAINER_ID" gluster volume set "$VOLUME_NAME" performance.cache-size 128MB
docker exec "$CONTAINER_ID" gluster volume set "$VOLUME_NAME" performance.write-behind-window-size 4MB

echo ""
echo "Step 6: Volume status..."
docker exec "$CONTAINER_ID" gluster volume info "$VOLUME_NAME"
docker exec "$CONTAINER_ID" gluster volume status "$VOLUME_NAME"

echo ""
echo "=== GlusterFS Initialization Complete ==="
echo ""
echo "Volume '$VOLUME_NAME' is ready for use"
echo ""
echo "To mount on a node:"
echo "  mkdir -p /mnt/gluster"
echo "  mount -t glusterfs 192.168.99.101:/$VOLUME_NAME /mnt/gluster"
echo ""
echo "Or use Docker volume driver:"
echo "  docker volume create --driver local \\"
echo "    --opt type=glusterfs \\"
echo "    --opt o=addr=192.168.99.101,vers=3 \\"
echo "    --opt device=:/$VOLUME_NAME \\"
echo "    my-gluster-volume"
echo ""
