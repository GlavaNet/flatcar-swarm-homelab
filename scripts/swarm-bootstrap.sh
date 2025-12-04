#!/bin/bash
# Flatcar Docker Swarm Zero-Touch Bootstrap Script
# This script handles automatic token distribution and cluster formation

set -euo pipefail

# Configuration
SWARM_MANAGER_PRIMARY="swarm-manager-1"
SWARM_ADVERTISE_ADDR=$(ip -4 route get 1.1.1.1 | grep -oP 'src \K\S+')
TOKEN_SERVER_PORT="8080"
TOKEN_DIR="/opt/swarm-tokens"
LOG_FILE="/var/log/swarm-bootstrap.log"

# Logging function
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Wait for Docker to be ready
wait_for_docker() {
    log "Waiting for Docker daemon..."
    local max_attempts=60
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if docker info >/dev/null 2>&1; then
            log "Docker is ready"
            return 0
        fi
        sleep 2
        attempt=$((attempt + 1))
    done
    
    log "ERROR: Docker failed to start after ${max_attempts} attempts"
    return 1
}

# Check if node is already in swarm
is_in_swarm() {
    docker info 2>/dev/null | grep -q "Swarm: active"
}

# Initialize swarm on primary manager
init_swarm() {
    log "Initializing Docker Swarm on primary manager..."
    
    if is_in_swarm; then
        log "Already in swarm mode, skipping initialization"
        return 0
    fi
    
    local ip_addr="$SWARM_ADVERTISE_ADDR"
    
    if [ -z "$ip_addr" ]; then
        log "ERROR: Could not determine IP address"
        return 1
    fi
    
    log "Initializing swarm with advertise address: $ip_addr"
    docker swarm init --advertise-addr "$ip_addr" || {
        log "ERROR: Failed to initialize swarm"
        return 1
    }
    
    # Create token directory
    mkdir -p "$TOKEN_DIR"
    
    # Store tokens
    docker swarm join-token -q manager > "$TOKEN_DIR/manager-token"
    docker swarm join-token -q worker > "$TOKEN_DIR/worker-token"
    
    # Store manager IP
    echo "$ip_addr" > "$TOKEN_DIR/manager-ip"
    
    log "Swarm initialized successfully"
    log "Manager token: $(cat $TOKEN_DIR/manager-token)"
    log "Worker token: $(cat $TOKEN_DIR/worker-token)"
    
    return 0
}

# Start simple HTTP server to serve tokens
start_token_server() {
    log "Starting token distribution server on port $TOKEN_SERVER_PORT..."
    
    # Kill existing server if running
    docker rm -f token-server 2>/dev/null || true
    
    # Start nginx container serving token directory
    docker run -d \
        --name token-server \
        --restart unless-stopped \
        -v "$TOKEN_DIR:/usr/share/nginx/html:ro" \
        -p "$TOKEN_SERVER_PORT:80" \
        nginx:alpine > /dev/null 2>&1
    
    log "Token server started (container: token-server)"
}

# Fetch token from primary manager
fetch_token() {
    local token_type="$1"  # "manager" or "worker"
    local manager_ip="$2"
    local max_attempts=60
    local attempt=0
    
    log "Fetching $token_type token from $manager_ip..."
    
    while [ $attempt -lt $max_attempts ]; do
        local token
        token=$(curl -sf "http://${manager_ip}:${TOKEN_SERVER_PORT}/${token_type}-token" 2>/dev/null) || true
        
        if [ -n "$token" ]; then
            log "Successfully retrieved $token_type token"
            echo "$token"
            return 0
        fi
        
        log "Attempt $((attempt + 1))/$max_attempts: Waiting for token server..."
        sleep 5
        attempt=$((attempt + 1))
    done
    
    log "ERROR: Failed to retrieve token after $max_attempts attempts"
    return 1
}

# Fetch manager IP from primary manager
fetch_manager_ip() {
    local discovery_ip="$1"
    local max_attempts=60
    local attempt=0
    
    log "Fetching manager IP from $discovery_ip..."
    
    while [ $attempt -lt $max_attempts ]; do
        local manager_ip
        manager_ip=$(curl -sf "http://${discovery_ip}:${TOKEN_SERVER_PORT}/manager-ip" 2>/dev/null) || true
        
        if [ -n "$manager_ip" ]; then
            log "Manager IP: $manager_ip"
            echo "$manager_ip"
            return 0
        fi
        
        log "Attempt $((attempt + 1))/$max_attempts: Waiting for manager IP..."
        sleep 5
        attempt=$((attempt + 1))
    done
    
    log "ERROR: Failed to retrieve manager IP after $max_attempts attempts"
    return 1
}

# Join swarm as manager
join_as_manager() {
    local primary_manager_ip="$1"
    
    log "Joining swarm as manager..."
    
    if is_in_swarm; then
        log "Already in swarm, skipping join"
        return 0
    fi
    
    local token
    token=$(fetch_token "manager" "$primary_manager_ip") || return 1
    
    local manager_ip
    manager_ip=$(fetch_manager_ip "$primary_manager_ip") || return 1
    
    log "Joining swarm at ${manager_ip}:2377 with manager token"
    docker swarm join --token "$token" "${manager_ip}:2377" 2>&1 | tee -a "$LOG_FILE" || {
        log "ERROR: Failed to join swarm as manager"
        return 1
    }
    
    log "Successfully joined swarm as manager"
    return 0
}

# Join swarm as worker
join_as_worker() {
    local primary_manager_ip="$1"
    
    log "Joining swarm as worker..."
    
    if is_in_swarm; then
        log "Already in swarm, skipping join"
        return 0
    fi
    
    local token
    token=$(fetch_token "worker" "$primary_manager_ip") || return 1
    
    local manager_ip
    manager_ip=$(fetch_manager_ip "$primary_manager_ip") || return 1
    
    log "Joining swarm at ${manager_ip}:2377 with worker token"
    docker swarm join --token "$token" "${manager_ip}:2377" 2>&1 | tee -a "$LOG_FILE" || {
        log "ERROR: Failed to join swarm as worker"
        return 1
    }
    
    log "Successfully joined swarm as worker"
    return 0
}

# Main execution
main() {
    local hostname
    hostname=$(hostname)
    local node_role="${SWARM_NODE_ROLE:-auto}"  # Set via environment: manager, worker, or auto
    local primary_manager_ip="${SWARM_PRIMARY_MANAGER_IP:-}"
    
    log "=== Starting Swarm Bootstrap on $hostname ==="
    log "Node role: $node_role"
    
    # Wait for Docker
    wait_for_docker || exit 1
    
    # Determine node role and action
    if [ "$hostname" = "$SWARM_MANAGER_PRIMARY" ]; then
        # This is the primary manager
        log "Running as primary manager node"
        init_swarm || exit 1
        start_token_server || exit 1
        
    elif [ "$node_role" = "manager" ] || [[ "$hostname" =~ manager ]]; then
        # This is a secondary manager
        log "Running as secondary manager node"
        
        if [ -z "$primary_manager_ip" ]; then
            log "ERROR: SWARM_PRIMARY_MANAGER_IP not set"
            exit 1
        fi
        
        join_as_manager "$primary_manager_ip" || exit 1
        
    elif [ "$node_role" = "worker" ] || [[ "$hostname" =~ worker ]]; then
        # This is a worker node
        log "Running as worker node"
        
        if [ -z "$primary_manager_ip" ]; then
            log "ERROR: SWARM_PRIMARY_MANAGER_IP not set"
            exit 1
        fi
        
        join_as_worker "$primary_manager_ip" || exit 1
        
    else
        log "ERROR: Unable to determine node role from hostname: $hostname"
        exit 1
    fi
    
    # Display cluster status
    log "=== Cluster Status ==="
    docker node ls 2>/dev/null || log "Not a manager node, cannot list nodes"
    
    log "=== Bootstrap Complete ==="
}

# Run main function
main "$@"
