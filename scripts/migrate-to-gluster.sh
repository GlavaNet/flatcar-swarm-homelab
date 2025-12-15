#!/bin/bash
# Migrate service data from local volumes to GlusterFS volumes

set -e

SERVICE="$1"

if [ -z "$SERVICE" ]; then
    echo "Usage: $0 <service-name>"
    echo ""
    echo "Available services:"
    echo "  forgejo"
    echo "  grafana"
    echo "  prometheus"
    echo "  vaultwarden"
    echo "  homeassistant"
    echo "  adguard"
    echo ""
    exit 1
fi

echo "=== Migrating $SERVICE to GlusterFS ==="
echo ""

# Get the stack name and volume names based on service
case "$SERVICE" in
    forgejo)
        STACK="forgejo"
        VOLUMES=("forgejo-data")
        ;;
    grafana)
        STACK="monitoring"
        VOLUMES=("grafana-data")
        ;;
    prometheus)
        STACK="monitoring"
        VOLUMES=("prometheus-data")
        ;;
    vaultwarden)
        STACK="vaultwarden"
        VOLUMES=("vaultwarden-data")
        ;;
    homeassistant)
        STACK="homeassistant"
        VOLUMES=("homeassistant-config")
        ;;
    adguard)
        STACK="adguard"
        VOLUMES=("adguard-work" "adguard-conf")
        ;;
    *)
        echo "ERROR: Unknown service: $SERVICE"
        exit 1
        ;;
esac

echo "Service: $SERVICE"
echo "Stack: $STACK"
echo "Volumes: ${VOLUMES[@]}"
echo ""

read -p "This will temporarily stop the service. Continue? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    echo "Aborted"
    exit 0
fi

# Step 1: Stop the service
echo ""
echo "Step 1: Scaling service to 0..."
SERVICE_NAME="${STACK}_${SERVICE}"
docker service scale "${SERVICE_NAME}"=0

echo "Waiting for service to stop..."
sleep 10

# Step 2: Copy data for each volume
for vol in "${VOLUMES[@]}"; do
    echo ""
    echo "Step 2: Migrating volume: $vol"
    
    SRC_VOL="${vol}"
    DST_VOL="${vol}-gluster"
    
    # Check if volumes exist
    if ! docker volume inspect "$SRC_VOL" >/dev/null 2>&1; then
        echo "  WARNING: Source volume $SRC_VOL not found, skipping"
        continue
    fi
    
    if ! docker volume inspect "$DST_VOL" >/dev/null 2>&1; then
        echo "  ERROR: Destination volume $DST_VOL not found"
        echo "  Run: scripts/create-gluster-volumes.sh first"
        exit 1
    fi
    
    echo "  Copying $SRC_VOL -> $DST_VOL"
    
    # Use a temporary container to copy data
    docker run --rm \
        -v "${SRC_VOL}:/source:ro" \
        -v "${DST_VOL}:/dest" \
        alpine:latest \
        sh -c "cp -av /source/. /dest/"
    
    echo "  ✓ Migration complete for $vol"
done

# Step 3: Update the service to use new volume
echo ""
echo "Step 3: Service migration complete"
echo ""
echo "Next steps:"
echo "  1. Update stack YAML to use GlusterFS volumes:"
echo "     - Change volume names to include '-gluster' suffix"
echo "     - Or use the updated stack files in stacks/${SERVICE}/"
echo ""
echo "  2. Redeploy the stack:"
echo "     docker stack deploy -c stacks/${STACK}/${STACK}-stack-gluster.yml ${STACK}"
echo ""
echo "  3. Verify data is accessible:"
echo "     docker service logs ${SERVICE_NAME}"
echo ""
echo "  4. Once verified working, remove old volumes:"
echo "     docker volume rm ${VOLUMES[@]}"
echo ""
