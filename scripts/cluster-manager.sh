#!/bin/bash
# Docker Swarm Cluster Management Utilities
# Run on a manager node for cluster administration

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo -e "\n${BLUE}===${NC} $1 ${BLUE}===${NC}\n"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}!${NC} $1"
}

# Display cluster status
cluster_status() {
    print_header "Cluster Status"
    
    echo "Nodes:"
    docker node ls
    
    echo -e "\nServices:"
    docker service ls
    
    echo -e "\nStacks:"
    docker stack ls
    
    echo -e "\nNetworks:"
    docker network ls --filter driver=overlay
    
    echo -e "\nVolumes:"
    docker volume ls
}

# Display node resource usage
node_resources() {
    print_header "Node Resource Usage"
    
    for node in $(docker node ls -q); do
        node_name=$(docker node inspect $node --format '{{.Description.Hostname}}')
        echo -e "\n${GREEN}Node: $node_name${NC}"
        
        # Get tasks running on this node
        docker node ps $node --format "table {{.Name}}\t{{.Image}}\t{{.CurrentState}}"
    done
    
    echo -e "\n${BLUE}Overall Container Stats:${NC}"
    docker stats --no-stream --format "table {{.Container}}\t{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}"
}

# Health check all services
health_check() {
    print_header "Service Health Check"
    
    services=$(docker service ls --format '{{.Name}}')
    
    for service in $services; do
        replicas=$(docker service ls --filter name=$service --format '{{.Replicas}}')
        
        if [[ $replicas =~ ^([0-9]+)/([0-9]+) ]]; then
            actual=${BASH_REMATCH[1]}
            desired=${BASH_REMATCH[2]}
            
            if [ "$actual" -eq "$desired" ]; then
                print_success "$service: $replicas"
            else
                print_error "$service: $replicas (unhealthy)"
                
                # Show recent logs
                echo "  Recent logs:"
                docker service logs --tail 5 $service 2>&1 | sed 's/^/    /'
            fi
        fi
    done
}

# Backup swarm configuration
backup_cluster() {
    print_header "Backing Up Cluster Configuration"
    
    backup_dir="swarm-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"
    
    # Backup swarm state
    print_success "Backing up swarm state..."
    sudo tar czf "$backup_dir/swarm-state.tar.gz" -C /var/lib/docker/swarm . 2>/dev/null || \
        print_warning "Could not backup swarm state (requires root)"
    
    # Export all stacks
    print_success "Exporting stacks..."
    for stack in $(docker stack ls --format '{{.Name}}'); do
        docker stack ps $stack --format '{{.Name}}\t{{.Image}}' > "$backup_dir/stack-$stack.txt"
    done
    
    # Export all configs
    print_success "Exporting configs..."
    docker config ls --format '{{.Name}}' > "$backup_dir/configs.txt"
    
    # Export all secrets
    print_success "Exporting secrets list..."
    docker secret ls --format '{{.Name}}' > "$backup_dir/secrets.txt"
    
    # Export node labels
    print_success "Exporting node configuration..."
    for node in $(docker node ls -q); do
        node_name=$(docker node inspect $node --format '{{.Description.Hostname}}')
        docker node inspect $node > "$backup_dir/node-$node_name.json"
    done
    
    print_success "Backup completed: $backup_dir"
    ls -lh "$backup_dir"
}

# Scale a service
scale_service() {
    local service=$1
    local replicas=$2
    
    if [ -z "$service" ] || [ -z "$replicas" ]; then
        print_error "Usage: $0 scale <service-name> <replica-count>"
        return 1
    fi
    
    print_header "Scaling Service"
    
    echo "Scaling $service to $replicas replicas..."
    docker service scale $service=$replicas
    
    sleep 2
    docker service ps $service
}

# Drain a node for maintenance
drain_node() {
    local node=$1
    
    if [ -z "$node" ]; then
        print_error "Usage: $0 drain <node-name>"
        return 1
    fi
    
    print_header "Draining Node: $node"
    
    print_warning "This will move all workloads off $node"
    read -p "Continue? (yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        print_error "Cancelled"
        return 0
    fi
    
    docker node update --availability drain $node
    print_success "Node $node is now draining"
    
    echo -e "\nMonitoring task migration..."
    sleep 3
    docker node ps $node
}

# Activate a drained node
activate_node() {
    local node=$1
    
    if [ -z "$node" ]; then
        print_error "Usage: $0 activate <node-name>"
        return 1
    fi
    
    print_header "Activating Node: $node"
    
    docker node update --availability active $node
    print_success "Node $node is now active"
}

# Clean up unused resources
cleanup() {
    print_header "Cleaning Up Unused Resources"
    
    print_warning "This will remove:"
    echo "  - Stopped containers"
    echo "  - Unused networks"
    echo "  - Dangling images"
    echo "  - Unused volumes"
    echo "  - Build cache"
    
    read -p "Continue? (yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        print_error "Cancelled"
        return 0
    fi
    
    docker system prune -af --volumes
    print_success "Cleanup complete"
}

# View logs for a service
view_logs() {
    local service=$1
    local lines=${2:-50}
    
    if [ -z "$service" ]; then
        print_error "Usage: $0 logs <service-name> [lines]"
        return 1
    fi
    
    print_header "Logs for $service (last $lines lines)"
    
    docker service logs --tail $lines --follow $service
}

# Update a service image
update_service() {
    local service=$1
    local image=$2
    
    if [ -z "$service" ]; then
        print_error "Usage: $0 update <service-name> [image]"
        return 1
    fi
    
    print_header "Updating Service: $service"
    
    if [ -n "$image" ]; then
        echo "Updating to new image: $image"
        docker service update --image $image $service
    else
        echo "Forcing update (will pull latest image)"
        docker service update --force $service
    fi
    
    sleep 2
    docker service ps $service
}

# Rollback a service
rollback_service() {
    local service=$1
    
    if [ -z "$service" ]; then
        print_error "Usage: $0 rollback <service-name>"
        return 1
    fi
    
    print_header "Rolling Back Service: $service"
    
    docker service rollback $service
    
    sleep 2
    docker service ps $service
}

# Inspect a service in detail
inspect_service() {
    local service=$1
    
    if [ -z "$service" ]; then
        print_error "Usage: $0 inspect <service-name>"
        return 1
    fi
    
    print_header "Inspecting Service: $service"
    
    echo "Service Details:"
    docker service inspect $service --pretty
    
    echo -e "\nTask Status:"
    docker service ps $service
    
    echo -e "\nLogs (last 20 lines):"
    docker service logs --tail 20 $service
}

# Monitor cluster in real-time
monitor() {
    print_header "Real-time Cluster Monitor"
    
    echo "Press Ctrl+C to exit"
    echo ""
    
    while true; do
        clear
        echo "=== Docker Swarm Cluster Monitor ==="
        echo "Updated: $(date)"
        echo ""
        
        echo "Nodes:"
        docker node ls
        
        echo -e "\nServices:"
        docker service ls
        
        echo -e "\nResource Usage:"
        docker stats --no-stream --format "table {{.Container}}\t{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"
        
        sleep 5
    done
}

# Create a new service interactively
create_service() {
    print_header "Create New Service"
    
    read -p "Service name: " name
    read -p "Image (e.g., nginx:alpine): " image
    read -p "Replicas (default: 1): " replicas
    replicas=${replicas:-1}
    read -p "Published port (e.g., 8080:80, or leave empty): " ports
    read -p "Network (leave empty for default): " network
    
    cmd="docker service create --name $name --replicas $replicas"
    
    if [ -n "$ports" ]; then
        cmd="$cmd --publish $ports"
    fi
    
    if [ -n "$network" ]; then
        cmd="$cmd --network $network"
    fi
    
    cmd="$cmd $image"
    
    echo -e "\nCommand to execute:"
    echo "$cmd"
    echo ""
    
    read -p "Create this service? (yes/no): " confirm
    
    if [ "$confirm" = "yes" ]; then
        eval $cmd
        print_success "Service created"
        sleep 2
        docker service ps $name
    else
        print_error "Cancelled"
    fi
}

# Generate cluster report
generate_report() {
    print_header "Generating Cluster Report"
    
    report_file="cluster-report-$(date +%Y%m%d-%H%M%S).txt"
    
    {
        echo "Docker Swarm Cluster Report"
        echo "Generated: $(date)"
        echo "=========================================="
        echo ""
        
        echo "NODES:"
        docker node ls
        echo ""
        
        echo "SERVICES:"
        docker service ls
        echo ""
        
        echo "STACKS:"
        docker stack ls
        echo ""
        
        echo "NETWORKS:"
        docker network ls --filter driver=overlay
        echo ""
        
        echo "VOLUMES:"
        docker volume ls
        echo ""
        
        echo "RESOURCE USAGE:"
        docker stats --no-stream
        echo ""
        
        echo "NODE DETAILS:"
        for node in $(docker node ls -q); do
            echo "---"
            docker node inspect $node --pretty
            echo ""
        done
        
    } > "$report_file"
    
    print_success "Report saved to: $report_file"
    cat "$report_file"
}

# Display menu
show_menu() {
    echo -e "\n${BLUE}Docker Swarm Cluster Manager${NC}"
    echo "=============================="
    echo "1)  Cluster Status"
    echo "2)  Node Resources"
    echo "3)  Health Check"
    echo "4)  Monitor (real-time)"
    echo "5)  View Service Logs"
    echo "6)  Inspect Service"
    echo "7)  Create Service"
    echo "8)  Update Service"
    echo "9)  Scale Service"
    echo "10) Rollback Service"
    echo "11) Drain Node"
    echo "12) Activate Node"
    echo "13) Backup Cluster"
    echo "14) Cleanup Resources"
    echo "15) Generate Report"
    echo "0)  Exit"
    echo ""
}

# Interactive mode
interactive_mode() {
    while true; do
        show_menu
        read -p "Select option: " choice
        
        case $choice in
            1) cluster_status ;;
            2) node_resources ;;
            3) health_check ;;
            4) monitor ;;
            5) 
                read -p "Service name: " svc
                read -p "Number of lines (default 50): " lines
                view_logs "$svc" "${lines:-50}"
                ;;
            6)
                read -p "Service name: " svc
                inspect_service "$svc"
                ;;
            7) create_service ;;
            8)
                read -p "Service name: " svc
                read -p "New image (leave empty to force update): " img
                update_service "$svc" "$img"
                ;;
            9)
                read -p "Service name: " svc
                read -p "Number of replicas: " reps
                scale_service "$svc" "$reps"
                ;;
            10)
                read -p "Service name: " svc
                rollback_service "$svc"
                ;;
            11)
                read -p "Node name: " node
                drain_node "$node"
                ;;
            12)
                read -p "Node name: " node
                activate_node "$node"
                ;;
            13) backup_cluster ;;
            14) cleanup ;;
            15) generate_report ;;
            0) 
                print_success "Goodbye!"
                exit 0
                ;;
            *)
                print_error "Invalid option"
                ;;
        esac
        
        echo ""
        read -p "Press Enter to continue..."
    done
}

# Main execution
main() {
    # Check if running on swarm manager
    if ! docker node ls &>/dev/null; then
        print_error "This script must be run on a Docker Swarm manager node"
        exit 1
    fi
    
    if [ $# -eq 0 ]; then
        # No arguments - run interactive mode
        interactive_mode
    else
        # Command-line mode
        case "$1" in
            status) cluster_status ;;
            resources) node_resources ;;
            health) health_check ;;
            monitor) monitor ;;
            logs) view_logs "${@:2}" ;;
            inspect) inspect_service "$2" ;;
            create) create_service ;;
            update) update_service "${@:2}" ;;
            scale) scale_service "$2" "$3" ;;
            rollback) rollback_service "$2" ;;
            drain) drain_node "$2" ;;
            activate) activate_node "$2" ;;
            backup) backup_cluster ;;
            cleanup) cleanup ;;
            report) generate_report ;;
            *)
                echo "Usage: $0 [command] [arguments]"
                echo ""
                echo "Commands:"
                echo "  status              Show cluster status"
                echo "  resources           Show node resources"
                echo "  health              Check service health"
                echo "  monitor             Real-time monitoring"
                echo "  logs <service>      View service logs"
                echo "  inspect <service>   Inspect service"
                echo "  create              Create new service"
                echo "  update <service>    Update service"
                echo "  scale <svc> <num>   Scale service"
                echo "  rollback <service>  Rollback service"
                echo "  drain <node>        Drain node"
                echo "  activate <node>     Activate node"
                echo "  backup              Backup cluster"
                echo "  cleanup             Clean up resources"
                echo "  report              Generate report"
                echo ""
                echo "Run without arguments for interactive mode"
                exit 1
                ;;
        esac
    fi
}

# Run main
main "$@"
