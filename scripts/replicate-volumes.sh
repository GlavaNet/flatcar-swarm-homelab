#!/bin/bash
# Replicate volumes across all manager nodes for redundancy

set -e

MANAGER_NODES=("192.168.99.101" "192.168.99.102" "192.168.99.103")
VOLUME_PATTERNS=("vaultwarden" "homeassistant" "forgejo" "grafana" "mealie" "adguard")
BACKUP_DIR="/backup/volumes"
LOG_FILE="/var/log/volume-replication.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Discover volumes on all nodes
declare -A VOLUME_LOCATIONS

for node in "${MANAGER_NODES[@]}"; do
    volumes=$(ssh -o ConnectTimeout=5 core@$node "docker volume ls --format '{{.Name}}'" 2>/dev/null || echo "")
    
    for pattern in "${VOLUME_PATTERNS[@]}"; do
        matching=$(echo "$volumes" | grep "$pattern" || true)
        for vol in $matching; do
            [ -n "$vol" ] && VOLUME_LOCATIONS["$vol"]="$node"
        done
    done
done

log "=== Volume Replication Starting ==="
log "Found ${#VOLUME_LOCATIONS[@]} volumes to replicate"

# Replicate each volume to other nodes
for vol in "${!VOLUME_LOCATIONS[@]}"; do
    source_node="${VOLUME_LOCATIONS[$vol]}"
    
    for target_node in "${MANAGER_NODES[@]}"; do
        # Skip if source == target
        [ "$source_node" = "$target_node" ] && continue
        
        log "Replicating $vol: $source_node → $target_node"
        
        # Stream from source to target
        ssh core@$source_node "docker run --rm -v ${vol}:/source:ro alpine tar czf - -C /source ." | \
        ssh core@$target_node "sudo mkdir -p ${BACKUP_DIR}/${vol} && sudo tar xzf - -C ${BACKUP_DIR}/${vol}" \
            && log "  ✓ $vol → $target_node" \
            || log "  ✗ Failed: $vol → $target_node"
    done
done

log "=== Replication Complete ==="
