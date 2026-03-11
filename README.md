# Flatcar Docker Swarm Homelab

A production-ready Docker Swarm cluster built on Flatcar Container Linux for Raspberry Pi 4. This project implements zero-touch deployment, automated GitOps workflows, and just-in-time resource management to maximize efficiency on constrained hardware.

## Why This Project Exists

I built this homelab to learn container orchestration without the overhead of running Kubernetes on Raspberry Pis. While k3s is popular for this use case, I found Docker Swarm offered better resource efficiency (using about 40% less memory) while still teaching the fundamental concepts of cluster management, service discovery, and declarative infrastructure.

The goals here are straightforward: understand how production container orchestration works, implement real GitOps patterns, and run actual services I use daily—all while staying within the constraints of hardware I can actually afford. This serves as my stepping stone to Kubernetes. Once these patterns are second nature, the transition to k8s will be about learning new syntax rather than new concepts.

## Quick Start

The complete setup process:

1. **Configure**: Edit `scripts/deploy-flatcar-pi.sh` with your network settings
2. **Flash**: Run `./deploy-flatcar-pi.sh` to flash SD cards
3. **Boot**: Insert cards and power on all Raspberry Pis
4. **Bootstrap**: Run `./deploy-bootstrap.sh` from your host machine

That's it. The bootstrap script handles swarm initialization, cluster configuration, and service deployment automatically. The whole process takes about 15-20 minutes from flashing to a fully operational cluster.

## Architecture Overview

The cluster runs three manager nodes for high availability, plus worker nodes for application workloads. Manager nodes use static IPs (192.168.99.101-103) and bootstrap automatically—no manual work required. The primary manager starts the cluster and makes join tokens available over HTTP, so other nodes can discover and join without any intervention from me.

Services deploy as Docker stacks with persistent volumes. Traefik handles incoming requests and SSL/TLS. Prometheus and Grafana provide monitoring. Everything is defined in code and deployed through a pipeline that pulls from GitHub every five minutes.

### Just-in-Time Services

One challenge with Raspberry Pi clusters is memory. Running everything simultaneously isn't viable on 2GB nodes. I implemented a just-in-time service system where rarely-used services scale to zero when idle and automatically start on access. A webhook receiver listens on port 9999 and scales services up on demand. Services auto-shutdown after their timeout period (30-60 minutes).

This approach lets me run more services than would otherwise fit in memory, while keeping frequently-used services always available.

## What's Running

**Infrastructure Services:**
- Docker Swarm orchestration across 4 nodes
- Traefik reverse proxy with automatic service discovery
- Prometheus and Grafana for metrics and visualization
- AdGuard Home for DNS and ad-blocking

**Application Services (JIT):**
- Vaultwarden for password management
- Forgejo for Git hosting and mirroring GitHub repos
- Mealie for recipe management
- MinIO for S3-compatible object storage and backups

**Optional Integration:**
- Tailscale for secure remote access
- Home Assistant for home automation

The "JIT" designation means these services scale to zero when not in use and start automatically when accessed.

## Hardware Requirements

- 4x Raspberry Pi 4B (2GB minimum, 4GB recommended)
- 4x microSD cards, 16GB or larger
- Network switch and Ethernet cables
- A computer running Linux for the initial setup

I'm using the 2GB Pi 4 models because that's what I had available. The 4GB models would provide more headroom, but the JIT system makes 2GB workable.

## Installation Process

The setup is a three-step process: configure and flash SD cards, boot the nodes, then run one bootstrap script that handles everything else automatically.

### Step 1: Initial Setup and Configuration

Clone this repository to your Linux machine. This repo stays on your host—it never gets cloned to the Pis:

```bash
git clone https://github.com/YOUR_USERNAME/flatcar-swarm-homelab.git
cd flatcar-swarm-homelab
```

Edit `scripts/deploy-flatcar-pi.sh` to configure your network:

```bash
declare -A NODES=(
    ["swarm-manager-1"]="manager|192.168.99.101"
    ["swarm-manager-2"]="manager|192.168.99.102"
    ["swarm-manager-3"]="manager|192.168.99.103"
    ["swarm-worker-1"]="worker|192.168.99.111"
)
```

Adjust these IPs to match your network. The script expects your SSH public key at `~/.ssh/id_rsa.pub`.

### Step 2: Flash SD Cards

Run the deployment script:

```bash
cd scripts
./deploy-flatcar-pi.sh
```

The script generates configurations, downloads Flatcar Container Linux and the Raspberry Pi UEFI firmware, then guides you through flashing each SD card. You'll insert one card at a time, confirm the device, and let the script handle the installation.

This process takes about 10 minutes per card.

### Step 3: Boot and Bootstrap

Insert the SD cards into your Raspberry Pis, connect Ethernet, and power them on. Wait about 3-5 minutes for all nodes to finish booting and become accessible via SSH.

Once the nodes are up, run the bootstrap script from your host machine:

```bash
cd scripts
./deploy-bootstrap.sh
```

This script automates the complete cluster setup:

1. **Swarm Initialization**: Connects to each node, initializes the swarm on the primary manager, and joins all remaining nodes
2. **Cluster Configuration**: Runs `cluster-init.sh` on manager-1, which:
   - Sets up the git-poll service for automated GitOps deployments
   - Configures backup services and schedules
   - Installs JIT service management scripts
3. **Service Deployment**: Automatically deploys all services by calling `deploy-services.sh`:
   - Traefik reverse proxy
   - Monitoring stack (Prometheus, Grafana, Alertmanager)
   - Forgejo git server
   - Vaultwarden password manager
   - Home Assistant
   - Mealie recipe manager
   - MinIO object storage
   - AdGuard Home (if configured)
   - Tailscale (if configured)
   - JIT infrastructure (webhook receiver and catchall service)

The entire process takes 5-10 minutes. You'll see progress output as each step completes.

Verify the cluster is running:

```bash
ssh core@192.168.99.101
docker node ls
```

You should see all four nodes with three showing as managers.

Check deployed services:

```bash
docker service ls
```

You should see all services running. Note that JIT services (Forgejo, Mealie, Vaultwarden, MinIO) will show 0/0 replicas—this is expected as they scale to zero when idle.

### DNS Configuration

After deployment completes, add these entries to your local machine's hosts file to access services:

**Linux/Mac:** `/etc/hosts`  
**Windows:** `C:\Windows\System32\drivers\etc\hosts`

```
192.168.99.101  git.local grafana.local prometheus.local adguard.local vault.local traefik.local recipes.local minio.local
```

Alternatively, configure AdGuard Home (at `http://192.168.99.101:3000`) to handle DNS for your entire network once it's deployed.

## Automated Deployment

The cluster implements continuous deployment through a git-poll service that was automatically configured during bootstrap. This service checks GitHub every five minutes. When changes are detected, the system automatically pulls updates and redeploys affected services.

The workflow:
1. Push changes to GitHub
2. Git-poll detects changes within 5 minutes
3. Services redeploy automatically with zero downtime

This is real GitOps—the cluster's state is defined in Git, and the cluster continuously reconciles itself to match that state.

### Manual Deployment

If you need to trigger an immediate deployment or redeploy services manually, you have two options:

From your host machine (requires the repository to be present on manager-1):
```bash
ssh core@192.168.99.101
cd ~/flatcar-swarm-homelab
git pull origin main
bash scripts/deploy-services.sh
```

Or redeploy individual stacks from any manager:

```bash
ssh core@192.168.99.101
docker stack deploy -c /opt/stacks/monitoring/monitoring-stack.yml monitoring
```

Note: The automated git-poll service will pull changes to manager-1 automatically, so you typically don't need to clone the repo there unless you're doing development work.

## Just-in-Time Services

The JIT system is designed to maximize available resources on memory-constrained nodes.

### How It Works

Services configured for JIT start at zero replicas. When you access their URL, Traefik routes the request to a catch-all service that displays a splash page and triggers a webhook to start the actual service. The service scales up, and once healthy, Traefik routes traffic to it. After the configured timeout period, the service scales back to zero.

### Managing JIT Services

Check service status:

```bash
ssh core@192.168.99.101
/opt/bin/jit-services.sh status
```

Manually start a service:

```bash
/opt/bin/jit-services.sh start mealie_mealie
```

Stop a service immediately:

```bash
/opt/bin/jit-services.sh stop mealie_mealie
```

### Webhook Endpoints

The webhook receiver listens on port 9999:

```bash
# Start a service manually
curl -X POST http://192.168.99.101:9999/start/mealie

# Health check
curl http://192.168.99.101:9999/health
```

## Service Configuration

These configurations are optional and can be done either before running `deploy-bootstrap.sh` (so services deploy with proper credentials) or after the cluster is running.

### Tailscale

For secure remote access, configure Tailscale before deployment:

```bash
cd scripts
./setup-tailscale-secrets.sh
```

Generate a reusable auth key in the Tailscale admin console with these settings enabled:
- Reusable
- Pre-authorized  
- Tagged (use `tag:homelab`)

If you configure Tailscale after the cluster is already running, redeploy the Tailscale stack:
```bash
ssh core@192.168.99.101
docker stack deploy -c /opt/stacks/tailscale/tailscale-stack.yml tailscale
```

The stack deploys three instances (one per manager) for redundancy. After deployment, enable subnet routes and exit node functionality in the Tailscale admin console.

### AdGuard Home

Configure credentials before deployment to have AdGuard automatically deployed:

```bash
cd scripts
./setup-adguard-secrets.sh
```

If you skip this step, AdGuard won't be deployed. You can configure it later and manually deploy:
```bash
ssh core@192.168.99.101
docker stack deploy -c /opt/stacks/adguard/adguard-stack.yml adguard
```

AdGuard provides DNS filtering, ad blocking, and local DNS resolution for `.local` domains.

## Monitoring and Observability

Prometheus collects metrics from all nodes and services. Grafana provides visualization through pre-configured dashboards. The monitoring stack includes:

- Node exporter for system metrics (CPU, memory, disk)
- cAdvisor for container metrics
- Prometheus with 7-day retention
- Grafana with custom Swarm dashboard
- Alertmanager with ntfy.sh integration for push notifications

Access Grafana at `http://grafana.local` (default credentials: admin/admin).

## Backup and Recovery

MinIO provides S3-compatible object storage. The backup system runs daily at 2 AM, automatically starting MinIO if needed, backing up all critical volumes, and scaling MinIO back down after completion.

Volume locations:
- Docker volumes: `/var/lib/docker/volumes`
- Stack configurations: `/opt/stacks`

Create a backup manually:

```bash
ssh core@192.168.99.101
sudo systemctl start minio-backup.service
```

Backups are stored in the MinIO `backups` bucket. Access the MinIO console at `http://minio.local` with credentials from `/opt/secrets/.minio-password`.

## Maintenance

### Viewing Logs

```bash
# Service logs
ssh core@192.168.99.101
docker service logs -f monitoring_prometheus

# Bootstrap logs  
journalctl -u swarm-bootstrap.service

# Automated deployment logs
sudo journalctl -u git-poll.service -f
```

### Updating Services

Modify the stack YAML in your local repository, then redeploy from your host machine:

```bash
cd scripts
./deploy-services.sh
```

Docker Swarm performs rolling updates automatically.

### Adding Nodes

Prepare a new SD card with the appropriate configuration, boot the node, run `deploy-bootstrap.sh` again to join it to the cluster. Verify with `docker node ls`.

### Removing Nodes

Drain services from the node:

```bash
ssh core@192.168.99.101
docker node update --availability drain NODE_ID
```

Wait for services to migrate, then leave the swarm:

```bash
ssh core@NODE_IP
docker swarm leave

# From a manager
ssh core@192.168.99.101
docker node rm NODE_ID
```

## Troubleshooting

### Node Won't Join Swarm

Check bootstrap logs on the node:

```bash
ssh core@NODE_IP
journalctl -u swarm-bootstrap.service
```

Verify network connectivity to the primary manager:

```bash
ping 192.168.99.101
curl http://192.168.99.101:8080/manager-token
```

Confirm `/etc/environment` has the correct `SWARM_PRIMARY_MANAGER_IP`.

### Service Won't Start

```bash
ssh core@192.168.99.101
docker service ps SERVICE_NAME
docker service logs SERVICE_NAME
docker service inspect SERVICE_NAME
```

Verify the service is on the correct network and has required secrets or configs.

### DNS Issues

Verify AdGuard is running:

```bash
ssh core@192.168.99.101
docker service ps adguard_adguard
```

Test DNS resolution:

```bash
nslookup git.local 192.168.99.101
```

Check that port 53 isn't in use by another service.

### Traefik Routing Problems

Check the Traefik dashboard at `http://traefik.local`. Verify service labels in the stack YAML match Traefik's expected format. Ensure services are on the `traefik-public` network.

## What I've Learned

Building this cluster taught me more about container orchestration than any tutorial could. The constraints of Raspberry Pi hardware forced me to think carefully about resource allocation and service lifecycle management. Implementing automated deployment from scratch clarified how continuous deployment should work in practice.

The JIT system was an interesting challenge. Balancing startup time, resource usage, and user experience required iteration. The current implementation is the third major revision, and I'm still finding edge cases.

The biggest lesson: distributed systems are hard. Services fail. Networks partition. Nodes crash. Building in observability and automated recovery from the start saves significant debugging time later.

## Next Steps

This homelab serves its purpose as a learning environment, but there are clear limitations. Docker Swarm's ecosystem is small compared to Kubernetes. Some tools I want to experiment with simply don't have Swarm support.

My plan is to continue running this cluster while building a parallel Kubernetes cluster (probably k3s) on separate hardware. The patterns and workflows I've established here should translate directly to k8s, with the main differences being in configuration syntax and the broader ecosystem of operators and controllers.

I'm particularly interested in exploring more sophisticated deployment tooling like Flux or ArgoCD, which are Kubernetes-native. The git-poll approach works fine for this cluster, but proper tooling would provide better state reconciliation and rollback capabilities.

## License

MIT License. Use this however you'd like. If it helps you learn something, that's all I'm hoping for.
