# Flatcar Docker Swarm Homelab

A production-ready Docker Swarm cluster built on Flatcar Container Linux for Raspberry Pi 4, featuring zero-touch deployment and automated GitOps workflows.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Overview

This project provides a complete infrastructure-as-code solution for deploying a high-availability Docker Swarm cluster on Raspberry Pi 4 devices. The system uses Flatcar Container Linux for immutable infrastructure and includes automated deployment pipelines, monitoring, and essential homelab services.

### Key Capabilities

**Infrastructure**: Docker Swarm cluster with 3 manager nodes and 1+ worker nodes, featuring automatic node discovery, self-healing services, and built-in load balancing. The cluster uses zero-touch bootstrapping where nodes automatically form a swarm without manual intervention.

**GitOps Automation**: Complete CI/CD pipeline with Forgejo (self-hosted Git), automated GitHub mirror synchronization, and automatic deployment of changes. Push to GitHub and changes automatically propagate to your cluster.

**Production Services**: Includes Traefik reverse proxy with SSL/TLS support, Prometheus and Grafana for monitoring, AdGuard Home for network-wide ad blocking, Vaultwarden for password management, and optional Tailscale integration for secure remote access.

**Resource Efficiency**: The system requires only 2GB RAM per node and uses 40% less memory compared to k3s or Kairos alternatives, while providing comparable functionality for homelab use cases.

## Architecture

The cluster consists of three manager nodes for high availability and quorum, with workers handling application workloads. Manager nodes run on static IPs (192.168.99.101-103) with automatic bootstrap coordination. The primary manager (swarm-manager-1) initializes the cluster and serves join tokens via HTTP, allowing secondary managers and workers to discover and join automatically.

Service discovery uses Docker's built-in DNS, with Traefik providing external routing. All services are deployed as Docker stacks with persistent volumes for stateful data. The system uses an overlay network architecture with separate networks for public-facing services (traefik-public), backend services, monitoring, and Tailscale networking.

## Prerequisites

Hardware requirements include 4x Raspberry Pi 4B with minimum 2GB RAM (4GB recommended), 4x microSD cards of 16GB or larger, and a network with DHCP or the ability to configure static IPs. For the setup process, you need a Linux computer with bash, wget, curl, jq, unzip, and standard tools.

Network configuration should provide either DHCP with reserved IPs or static IP assignment capability. The cluster requires ports 2377 (swarm management), 7946 (container network discovery), 4789 (overlay network traffic), 80 (HTTP), 443 (HTTPS), 53 (DNS for AdGuard), and 9001 (Portainer agent).

## Installation

### Step 1: Repository Setup

Clone the repository to your local machine:

```bash
git clone https://github.com/YOUR_USERNAME/flatcar-swarm-homelab.git
cd flatcar-swarm-homelab
```

### Step 2: Network Configuration

Edit `scripts/deploy-flatcar-pi.sh` and configure your node IP addresses:

```bash
declare -A NODES=(
    ["swarm-manager-1"]="manager|192.168.99.101"
    ["swarm-manager-2"]="manager|192.168.99.102"
    ["swarm-manager-3"]="manager|192.168.99.103"
    ["swarm-worker-1"]="worker|192.168.99.111"
)

PRIMARY_MANAGER_IP="192.168.99.101"
```

Ensure your SSH public key is available at `~/.ssh/id_rsa.pub` or set the `SSH_PUBLIC_KEY` environment variable.

### Step 3: Flash SD Cards

Run the deployment script which will generate Ignition configs, download Flatcar Container Linux, and guide you through flashing each SD card:

```bash
cd scripts
./deploy-flatcar-pi.sh
```

The script performs several automated tasks: generates node-specific Ignition configurations with static IPs and hostnames, downloads the flatcar-install tool and latest Raspberry Pi UEFI firmware, and provides an interactive process for flashing each SD card. You will be prompted to insert each card individually, confirm the target device, and the script will install Flatcar and UEFI firmware automatically.

### Step 4: Boot the Cluster

After flashing all cards, insert each SD card into its respective Raspberry Pi, connect Ethernet cables to your network, and power on all devices. The bootstrap process takes 3-5 minutes as nodes automatically discover and join the swarm.

### Step 5: Verify Cluster

SSH into the primary manager to check cluster status:

```bash
ssh core@192.168.99.101
docker node ls
```

You should see all four nodes listed with manager-1, manager-2, and manager-3 showing as managers and worker-1 as a worker.

### Step 6: Deploy Services

The cluster-init.sh script runs automatically on first boot, but you can also run it manually:

```bash
ssh core@192.168.99.101
cd ~/flatcar-swarm-homelab
bash scripts/deploy-services.sh
```

This deploys Traefik, Forgejo, monitoring stack, AdGuard Home (if configured), Vaultwarden, and optionally Tailscale.

### Step 7: Configure DNS

Add these entries to your local machine's /etc/hosts file (Linux/Mac) or C:\Windows\System32\drivers\etc\hosts (Windows):

```
192.168.99.101  git.local grafana.local prometheus.local adguard.local vault.local traefik.local
```

Alternatively, configure AdGuard Home to handle these domains cluster-wide.

### Step 8: Complete Service Setup

**Forgejo Setup**: Visit http://git.local and complete the initial configuration. Create an admin account and optionally set up a GitHub mirror for automated synchronization.

**Grafana**: Access at http://grafana.local with default credentials admin/admin. You will be prompted to change the password on first login.

**AdGuard Home**: Visit http://adguard.local to access the web interface. Initial credentials are set via the setup-adguard-secrets.sh script.

**Vaultwarden**: Access at http://vault.local and create your first account. The first registered user becomes the admin.

**Traefik Dashboard**: Monitor routing and services at http://traefik.local.

## Service Configuration

### Tailscale Integration

For secure remote access, configure Tailscale as a subnet router and exit node:

```bash
ssh core@192.168.99.101
cd ~/flatcar-swarm-homelab
./scripts/setup-tailscale-secrets.sh
```

Generate a reusable auth key from the Tailscale admin console with reusable, pre-authorized, and tagged settings enabled. The stack deploys three instances (one per manager) for redundancy. After deployment, enable subnet routes (192.168.99.0/24) and exit node functionality in the Tailscale admin console for each node.

### AdGuard Home

Configure AdGuard credentials before deployment:

```bash
./scripts/setup-adguard-secrets.sh
```

The service includes pre-configured filter lists (AdGuard DNS filter, Steven Black's Unified Hosts, OISD), DNS rewrites for local services, and upstream DNS with Quad9 and Cloudflare over HTTPS. AdGuard listens on port 53 (TCP/UDP) for DNS queries and provides a web interface through Traefik.

### Monitoring

The monitoring stack includes Prometheus for metrics collection with 7-day retention, Grafana for visualization and dashboards, node-exporter running on all nodes for system metrics, and cAdvisor for container metrics. Prometheus automatically discovers and scrapes all exporters using Docker Swarm DNS service discovery.

## GitOps Workflow

### Automated Deployment

The system implements continuous deployment through two mechanisms. Forgejo mirror sync runs every 10 minutes, pulling changes from GitHub, and git-poll runs every 5 minutes, checking for changes and automatically redeploying affected stacks.

The workflow is: push changes to GitHub, Forgejo syncs the repository within 10 minutes, git-poll detects changes within 5 minutes, and services are automatically redeployed with zero downtime using Docker Swarm's rolling updates.

### Manual Deployment

For immediate deployments, SSH into the primary manager and run:

```bash
cd ~/flatcar-swarm-homelab
git pull origin main
bash scripts/deploy-services.sh
```

Individual stacks can be redeployed separately:

```bash
docker stack deploy -c stacks/monitoring/monitoring-stack.yml monitoring
```

## Maintenance

### Viewing Logs

Check service logs using Docker commands:

```bash
# View logs for a specific service
docker service logs traefik_traefik

# Follow logs in real-time
docker service logs -f monitoring_prometheus

# View bootstrap logs
journalctl -u swarm-bootstrap.service
```

### Updating Services

Update service images by modifying the stack YAML file and redeploying:

```bash
docker stack deploy -c stacks/SERVICE/SERVICE-stack.yml SERVICE
```

Docker Swarm performs rolling updates automatically, maintaining service availability.

### Backup and Recovery

Important data locations include /var/lib/docker/volumes for Docker volumes (Grafana data, Prometheus data, Forgejo repositories, Vaultwarden database, AdGuard configuration) and /home/core/flatcar-swarm-homelab for stack configurations.

Create backups regularly:

```bash
# Backup all volumes
sudo tar czf /backup/docker-volumes-$(date +%Y%m%d).tar.gz /var/lib/docker/volumes

# Backup specific service data
docker run --rm -v forgejo-data:/data -v /backup:/backup alpine tar czf /backup/forgejo-$(date +%Y%m%d).tar.gz /data
```

### Cluster Management

Add new worker nodes by preparing a new SD card with worker configuration, booting the node (it joins automatically), and verifying with `docker node ls`. Remove nodes gracefully with `docker node update --availability drain NODE_ID`, wait for services to migrate, then use `docker swarm leave` on the node and `docker node rm NODE_ID` from a manager.

## Troubleshooting

### Node Won't Join Swarm

If a node fails to join, check the bootstrap logs with `journalctl -u swarm-bootstrap.service`, verify network connectivity to the primary manager (ping 192.168.99.101), confirm the SWARM_PRIMARY_MANAGER_IP is set correctly in /etc/environment, and ensure the token server is running on the primary manager (curl http://192.168.99.101:8080/manager-token).

### Service Won't Start

Troubleshoot service issues by checking the service status (`docker service ps SERVICE_NAME`), viewing detailed logs (`docker service logs SERVICE_NAME`), inspecting the service configuration (`docker service inspect SERVICE_NAME`), and verifying network connectivity (`docker network ls`).

### DNS Resolution Issues

For DNS problems, verify AdGuard is running (`docker service ps adguard_adguard`), check that port 53 is not in use by another service, test DNS resolution (`nslookup git.local 192.168.99.101`), and review AdGuard configuration in the web interface.

### Traefik Routing Issues

When services are not accessible through Traefik, check the Traefik dashboard (http://traefik.local) for registered routes, verify service labels are correct in the stack YAML, ensure services are on the traefik-public network, and check Traefik logs for errors.

## Project Structure

```
flatcar-swarm-homelab/
├── configs/                    # Flatcar Ignition configurations
│   ├── manager-node.yaml      # Manager node template
│   └── worker-node.yaml       # Worker node template
├── docs/                       # Additional documentation
├── scripts/                    # Deployment and setup scripts
│   ├── deploy-flatcar-pi.sh   # Main SD card flashing script
│   ├── swarm-bootstrap.sh     # Zero-touch cluster formation
│   ├── cluster-init.sh        # Initial service deployment
│   ├── deploy-services.sh     # Deploy all stacks
│   ├── setup-tailscale-secrets.sh
│   └── setup-adguard-secrets.sh
├── stacks/                     # Docker Swarm stack definitions
│   ├── traefik/
│   ├── forgejo/
│   ├── monitoring/
│   ├── adguard/
│   ├── vaultwarden/
│   └── tailscale/
└── README.md
```

## Technical Details

### Bootstrap Process

The swarm-bootstrap.sh script implements zero-touch cluster formation. The primary manager initializes the swarm, generates join tokens, and starts an HTTP server on port 8080 to distribute tokens. Secondary managers and workers fetch tokens from the primary manager, retrieve the manager IP address, and join the cluster automatically. The entire process is idempotent and handles failures with automatic retries.

### Security Considerations

The system uses Docker secrets for sensitive data (Tailscale auth keys, AdGuard credentials), SSH key-based authentication only (password auth disabled), Flatcar Container Linux with automatic security updates disabled for stability, and isolated overlay networks for service segmentation. All services run as non-root users where possible, and Traefik can be configured with Let's Encrypt for automatic TLS certificates.

### Resource Usage

Typical resource consumption per node includes approximately 400-600MB RAM at idle, 200-300MB RAM per deployed service stack, minimal CPU usage during normal operation, and storage requirements of 8GB base system plus 2-4GB per service with logs and data.

## Documentation

Detailed documentation is available in the docs/ directory covering installation procedures, GitOps pipeline configuration, example stack deployments, and troubleshooting guides.

## Contributing

Contributions are welcome. Please open an issue to discuss proposed changes before submitting pull requests. Ensure all scripts are tested on Raspberry Pi 4 hardware and maintain compatibility with the current Flatcar stable release.

## License

This project is licensed under the MIT License. See the LICENSE file for details.

## Acknowledgments

Built on Flatcar Container Linux, an immutable Linux distribution designed for containers. Uses Docker Swarm for orchestration, providing a simpler alternative to Kubernetes for homelab deployments. Inspired by the self-hosted community and various homelab projects demonstrating the power of running your own infrastructure.

## Support

For issues and questions, open an issue on GitHub or consult the troubleshooting documentation. The project is maintained as a community resource for running production-grade container infrastructure on Raspberry Pi hardware.
# Test
