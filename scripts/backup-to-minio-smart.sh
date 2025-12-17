#!/bin/bash
# Automated backup to MinIO - discovers volumes across all nodes

set -e

MANAGER_NODES=("192.168.99.101" "192.168.99.102" "192.168.99.103")
VOLUME_PATTERNS=("vaultwarden" "homeassistant" "forgejo" "grafana" "mealie" "adguard")
DATE=$(date +%Y%m%d-%H%M)
MINIO_PASSWORD=$(cat ~/.minio-password)
CURRENT_NODE=$(hostname -I | awk '{print $1}')
LOCK_FILE="/tmp/minio-backup.lock"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Lock mechanism - only one backup runs across cluster
if ! mkdir "$LOCK_FILE" 2>/dev/null; then
    log "Backup already running, exiting"
    exit 0
fi
trap "rmdir $LOCK_FILE 2>/dev/null" EXIT

# Find which node has which volumes
declare -A VOLUME_LOCATIONS

for node in "${MANAGER_NODES[@]}"; do
    log "Scanning volumes on $node..."
    
    if [ "$node" = "$CURRENT_NODE" ]; then
        volumes=$(docker volume ls --format '{{.Name}}')
    else
        volumes=$(ssh -o BatchMode=yes -o ConnectTimeout=5 core@$node "docker volume ls --format '{{.Name}}'" 2>/dev/null || echo "")
    fi
    
    for pattern in "${VOLUME_PATTERNS[@]}"; do
        matching=$(echo "$volumes" | grep "$pattern" || true)
        
        for vol in $matching; do
            if [ -n "$vol" ]; then
                VOLUME_LOCATIONS["$vol"]="$node"
            fi
        done
    done
done

# Backup each discovered volume
for vol in "${!VOLUME_LOCATIONS[@]}"; do
    node="${VOLUME_LOCATIONS[$vol]}"
    
    log "Backing up $vol from $node..."
    
    if [ "$node" = "$CURRENT_NODE" ]; then
        # Local backup
        docker run --rm -v ${vol}:/source:ro alpine:latest tar czf - -C /source . | \
        docker run --rm -i --network host --entrypoint /bin/sh minio/mc:latest \
            -c "mc alias set homelab http://localhost:9000 minioadmin ${MINIO_PASSWORD} && mc pipe homelab/backups/${vol}-${DATE}.tar.gz"
    else
        # Remote backup
        ssh -o BatchMode=yes core@$node "docker run --rm -v ${vol}:/source:ro alpine tar czf - -C /source ." | \
        docker run --rm -i --network host --entrypoint /bin/sh minio/mc:latest \
            -c "mc alias set homelab http://localhost:9000 minioadmin ${MINIO_PASSWORD} && mc pipe homelab/backups/${vol}-${DATE}.tar.gz"
    fi
    
    log "✓ Backed up $vol (from $node)"
done

log "=== Backup Summary ==="
log "Backed up ${#VOLUME_LOCATIONS[@]} volumes to MinIO"
