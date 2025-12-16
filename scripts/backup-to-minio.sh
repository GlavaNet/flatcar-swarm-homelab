#!/bin/bash
# Automated backup to MinIO - discovers volumes across all nodes

set -e

MANAGER_NODES=("192.168.99.101" "192.168.99.102" "192.168.99.103")
VOLUME_PATTERNS=("vaultwarden" "homeassistant" "forgejo" "grafana" "mealie" "adguard")
DATE=$(date +%Y%m%d-%H%M)
MINIO_PASSWORD=$(cat ~/.minio-password)

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Find which node has which volumes
declare -A VOLUME_LOCATIONS

for node in "${MANAGER_NODES[@]}"; do
    log "Scanning volumes on $node..."
    
    volumes=$(ssh -o ConnectTimeout=5 core@$node "docker volume ls --format '{{.Name}}'" 2>/dev/null || echo "")
    
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
    
    if [ "$node" = "$(hostname -I | awk '{print $1}')" ] || [ "$node" = "192.168.99.101" ]; then
        # Local backup
        docker run --rm \
            -v ${vol}:/source:ro \
            alpine:latest \
            tar czf - -C /source . | \
        docker run --rm -i \
            -e MC_HOST_homelab="http://minioadmin:${MINIO_PASSWORD}@192.168.99.101:9000" \
            minio/mc:latest \
            mc pipe homelab/backups/${vol}-${DATE}.tar.gz
    else
        # Remote backup
        ssh core@$node "docker run --rm -v ${vol}:/source:ro alpine tar czf - -C /source ." | \
        docker run --rm -i \
            -e MC_HOST_homelab="http://minioadmin:${MINIO_PASSWORD}@192.168.99.101:9000" \
            minio/mc:latest \
            mc pipe homelab/backups/${vol}-${DATE}.tar.gz
    fi
    
    log "✓ Backed up $vol (from $node)"
done

log "=== Backup Summary ==="
log "Backed up ${#VOLUME_LOCATIONS[@]} volumes to MinIO"
