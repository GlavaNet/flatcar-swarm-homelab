#!/bin/bash
# cluster-init.sh - Updated with JIT Services Integration

set -e

REPO_URL="https://github.com/YOUR_USERNAME/flatcar-swarm-homelab.git"
REPO_DIR="/home/core/flatcar-swarm-homelab"

echo "=== Flatcar Swarm Cluster Initialization ==="
echo ""

# Clone repository if needed
if [ ! -d "$REPO_DIR" ]; then
    echo "Cloning repository..."
    git clone "$REPO_URL" "$REPO_DIR"
fi

cd "$REPO_DIR"

# Setup SSH keys between managers
echo "=== Setting up SSH keys between managers ==="
MANAGER_NODES=("192.168.99.102" "192.168.99.103")

if [ ! -f ~/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa
    echo "✓ Generated SSH key on manager-1"
fi

for node in "${MANAGER_NODES[@]}"; do
    echo "Setting up keys with $node..."
    cat ~/.ssh/id_rsa.pub | ssh -o StrictHostKeyChecking=no core@$node "cat >> ~/.ssh/authorized_keys"
    ssh core@$node 'if [ ! -f ~/.ssh/id_rsa ]; then ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa; fi && cat ~/.ssh/id_rsa.pub' >> ~/.ssh/authorized_keys
done

ssh core@192.168.99.102 "cat ~/.ssh/id_rsa.pub" | ssh core@192.168.99.103 "cat >> ~/.ssh/authorized_keys"
ssh core@192.168.99.103 "cat ~/.ssh/id_rsa.pub" | ssh core@192.168.99.102 "cat >> ~/.ssh/authorized_keys"

for node in 192.168.99.101 "${MANAGER_NODES[@]}"; do
    if [ "$node" = "192.168.99.101" ]; then
        sort -u ~/.ssh/authorized_keys > /tmp/auth && mv /tmp/auth ~/.ssh/authorized_keys
    else
        ssh core@$node 'sort -u ~/.ssh/authorized_keys > /tmp/auth && mv /tmp/auth ~/.ssh/authorized_keys'
    fi
done

echo "✓ SSH keys distributed"

# Generate TLS certificates
echo ""
echo "=== Generating TLS certificates ==="
scripts/generate-local-certs.sh || {
    mkdir -p /home/core/certs
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /home/core/certs/vault.key \
        -out /home/core/certs/vault.crt \
        -subj "/CN=vault.local" \
        -addext "subjectAltName=DNS:vault.local" 2>/dev/null
}

# Install JIT Services
echo ""
echo "=== Installing JIT Services ==="

# Install JIT management script
sudo cp scripts/jit-services.sh /opt/bin/ 2>/dev/null || {
    echo "Creating JIT services script..."
    sudo tee /opt/bin/jit-services.sh > /dev/null << 'EOFJIT'
#!/bin/bash
set -e
SERVICES_DIR="/home/core/jit-services"
LOG_FILE="/var/log/jit-services.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
declare -A JIT_SERVICES=(
    ["mealie_mealie"]="60"
    ["minio_minio"]="30"
    ["forgejo_forgejo"]="60"
    ["vaultwarden_vaultwarden"]="60"
)
start_service() {
    local service="$1"
    local timeout="${JIT_SERVICES[$service]:-30}"
    log "Starting $service (auto-shutdown in ${timeout}m)"
    docker service scale "${service}=1"
    mkdir -p "$SERVICES_DIR"
    echo "$(date -d "+${timeout} minutes" +%s)" > "$SERVICES_DIR/${service}.shutdown"
    log "✓ $service started"
}
stop_service() {
    local service="$1"
    log "Stopping $service"
    docker service scale "${service}=0"
    rm -f "$SERVICES_DIR/${service}.shutdown"
    log "✓ $service stopped"
}
check_auto_shutdown() {
    local now=$(date +%s)
    for service in "${!JIT_SERVICES[@]}"; do
        local shutdown_file="$SERVICES_DIR/${service}.shutdown"
        if [ -f "$shutdown_file" ]; then
            local shutdown_time=$(cat "$shutdown_file")
            if [ "$now" -ge "$shutdown_time" ]; then
                log "Auto-shutdown triggered for $service"
                stop_service "$service"
            fi
        fi
    done
}
status_service() {
    local service="$1"
    local replicas=$(docker service ls --filter "name=${service}" --format "{{.Replicas}}" 2>/dev/null || echo "0/0")
    local running=$(echo "$replicas" | cut -d'/' -f1)
    if [ "$running" = "0" ]; then echo "stopped"; else echo "running"; fi
}
case "${1:-}" in
    start) [ -n "$2" ] && start_service "$2" || echo "Usage: $0 start <service_name>" ;;
    stop) [ -n "$2" ] && stop_service "$2" || echo "Usage: $0 stop <service_name>" ;;
    check) check_auto_shutdown ;;
    status)
        echo "JIT Service Status:"
        for service in "${!JIT_SERVICES[@]}"; do
            status=$(status_service "$service")
            timeout="${JIT_SERVICES[$service]}"
            if [ "$status" = "running" ]; then
                shutdown_file="$SERVICES_DIR/${service}.shutdown"
                if [ -f "$shutdown_file" ]; then
                    remaining=$(( ($(cat "$shutdown_file") - $(date +%s)) / 60 ))
                    echo "  $service: ✓ RUNNING (auto-stop in ${remaining}m)"
                else
                    echo "  $service: ✓ RUNNING"
                fi
            else
                echo "  $service: ○ STOPPED (timeout: ${timeout}m)"
            fi
        done
        ;;
    *) echo "Usage: $0 {start|stop|status|check} [service_name]"; exit 1 ;;
esac
EOFJIT
    sudo chmod +x /opt/bin/jit-services.sh
}

# Install auto-shutdown timer
sudo tee /etc/systemd/system/jit-checker.service > /dev/null << 'EOF'
[Unit]
Description=JIT Service Auto-Shutdown Checker
After=docker.service

[Service]
Type=oneshot
ExecStart=/opt/bin/jit-services.sh check

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/jit-checker.timer > /dev/null << 'EOF'
[Unit]
Description=Check JIT services every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable jit-checker.timer
sudo systemctl start jit-checker.timer

echo "✓ JIT services installed"

# Deploy core services
echo ""
echo "=== Deploying Services ==="

if [ -f scripts/deploy-services.sh ]; then
    bash scripts/deploy-services.sh
else
    echo "Deploying manually..."
    
    # Deploy in order
    [ -d stacks/traefik ] && docker stack deploy -c stacks/traefik/traefik-stack.yml traefik
    sleep 10
    
    [ -d stacks/webhook-receiver ] && docker stack deploy -c stacks/webhook-receiver/webhook-receiver-stack.yml webhook-receiver
    [ -d stacks/jit-catchall ] && docker stack deploy -c stacks/jit-catchall/jit-catchall-stack.yml jit-catchall
    
    [ -d stacks/forgejo ] && docker stack deploy -c stacks/forgejo/forgejo-stack.yml forgejo
    [ -d stacks/mealie ] && docker stack deploy -c stacks/mealie/mealie-stack.yml mealie
    [ -d stacks/vaultwarden ] && docker stack deploy -c stacks/vaultwarden/vaultwarden-stack.yml vaultwarden
    [ -d stacks/monitoring ] && docker stack deploy -c stacks/monitoring/monitoring-stack.yml monitoring
fi

# Scale JIT services to 0
echo ""
echo "=== Scaling JIT Services to 0 ==="
docker service scale mealie_mealie=0 2>/dev/null || true
docker service scale forgejo_forgejo=0 2>/dev/null || true
docker service scale vaultwarden_vaultwarden=0 2>/dev/null || true

echo ""
echo "=== Cluster Initialization Complete ==="
echo ""
echo "JIT Services (auto-start on demand):"
echo "  • http://recipes.local → Mealie"
echo "  • http://git.local → Forgejo"
echo "  • http://vault.local → Vaultwarden"
echo ""
echo "Always-on Services:"
echo "  • http://traefik.local → Traefik Dashboard"
echo "  • http://grafana.local → Grafana"
echo "  • http://prometheus.local → Prometheus"
echo ""
echo "JIT Service Management:"
echo "  Status: /opt/bin/jit-services.sh status"
echo "  Start:  /opt/bin/jit-services.sh start <service>"
echo "  Stop:   /opt/bin/jit-services.sh stop <service>"
echo ""
