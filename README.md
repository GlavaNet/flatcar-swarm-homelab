# Flatcar Docker Swarm Homelab

## What this is

A production-ready Docker Swarm cluster built on Flatcar Container Linux for Raspberry Pi 4. This project implements zero-touch deployment, automated GitOps workflows, and just-in-time resource management to maximize efficiency on constrained hardware.

## Why This Project Exists

My homelab has been running on a single Proxmox server for a while, but if the lack of redundancy hasn't bit me several times, my power bill certainly has! I decided to migrate my homelab here to learn container orchestration with the resources I had available to me. Yes I could have spun up k3s, but I also wanted an immutable OS as a basis for the cluster so I could literally tear down the entire thing and spin it back up from scratch, with new Pis and new drives if necessary. I found Docker Swarm offered better resource efficiency (uses about 40% less memory, includes Traefik out of the box) while still teaching me fundamental concepts of cluster management, service discovery, and declarative infrastructure.

My goals were to understand how production (ish) container orchestration works, implement real GitOps patterns, and run actual services I already use.

I have some experience with bash scripting, but that wasn't my focus for the purposes of this homelab. I used Claude to help me write some of the automation scripts. I vetted the AI generated code, but there may be gotchas in there. If you find any, feel free to let me know.

## Architecture Overview

The cluster runs three manager nodes for high availability, plus worker nodes for application workloads. Manager nodes use static IPs (192.168.99.101-103) and bootstrap automatically—no manual work required. The primary manager starts the cluster and makes join tokens available over HTTP, so other nodes can discover and join without any intervention from me.

Services deploy as Docker stacks with persistent volumes. Traefik handles incoming requests and SSL/TLS from services that need it, like Vaultwarden, though I'm just using self-signed certs and mostly insecure endpoints since it's all behind my LAN and only accessible from my network or my Tailnet. Prometheus and Grafana for monitoring. Everything is defined in code and deployed through a pipeline that pulls from GitHub every five minutes.

### Just-in-Time Services

Running everything simultaneously isn't viable on my 2GB nodes. I implemented a just-in-time service system where services I don't need all the time scale to zero when idle and automatically start on access. A webhook receiver scales services up on demand. Services auto-shutdown after their timeout period (30-60 minutes).

This approach lets me reduce overhead on my limited RAM, while keeping frequently-used services always available. I leaned into AI for this.

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

## Hardware

- 4x Raspberry Pi 4B 2GB
- 4x 16 GB microSD cards, yes I know I should be using SSDs

## Installation Process

Note: some of this is documentation intended for others to be able to follow and repeat, but some of it is notes for my own reference.

### Initial Setup

I'm running Linux, so the documentation is Linux-based. I'm sure it could be adapted for Mac or Windows, but that's out of scope for what I'm doing here.

Clone the repository:
```bash
git clone https://github.com/YOUR_USERNAME/flatcar-swarm-homelab.git
cd flatcar-swarm-homelab
```

Edit `scripts/deploy-flatcar-pi.sh`, configure for your network:
```bash
declare -A NODES=(
    ["swarm-manager-1"]="manager|192.168.99.101"
    ["swarm-manager-2"]="manager|192.168.99.102"
    ["swarm-manager-3"]="manager|192.168.99.103"
    ["swarm-worker-1"]="worker|192.168.99.111"
)
```

Flatcar uses SSH keys instead of passwords. The script expects your SSH public key at `~/.ssh/id_rsa.pub`.

### Flashing SD Cards

Run the deployment script:
```bash
cd scripts
./deploy-flatcar-pi.sh
```

The script generates configurations, downloads Flatcar Container Linux and the Raspberry Pi UEFI firmware, then guides you through flashing each SD card.

### Booting the Cluster

Insert the SD cards into the Pis and power them on. The bootstrap process takes a few minutes. Nodes discover each other and form a cluster automatically.

Verify the cluster from any manager node:
```bash
ssh core@192.168.99.101
docker node ls
```

We should see four nodes: three managers and one worker.

### Initial Service Deployment

The `cluster-init.sh` script runs automatically on first boot. It can also be run manually:
```bash
ssh core@192.168.99.101
cd ~/flatcar-swarm-homelab
bash scripts/cluster-init.sh
```

This deploys the core infrastructure and sets up the automated deployment pipeline.

### DNS Configuration

Add entries to /etc/hosts:

```
192.168.99.101  git.local grafana.local prometheus.local adguard.local vault.local traefik.local recipes.local minio.local
```

## Automated Deployment

The cluster implements continuous deployment through a git-poll service that checks GitHub every five minutes. When changes are detected, the system automatically pulls updates and redeploys affected services.

Workflow:
1. Push changes to GitHub
2. Forgejo mirror syncs every 10 minutes
3. Git-poll detects changes every 5 minutes
4. Services redeploy automatically with zero downtime

This is real gitops—the cluster's state is defined in git, and the cluster continuously reconciles itself to match that state.

### Manual Deployment

```bash
ssh core@192.168.99.101
cd ~/flatcar-swarm-homelab
git pull origin main
bash scripts/deploy-services.sh
```

Deploy individual stacks:
```bash
docker stack deploy -c stacks/monitoring/monitoring-stack.yml monitoring
```

## Just-in-Time Services

The JIT setup is designed to maximize available resources on memory-constrained nodes.

### How It Works

Services configured for JIT start at zero replicas. When you access their URL, Traefik routes the request to a catch-all service that displays a splash page and triggers a webhook to start the actual service. The service scales up, then Traefik routes traffic to it. After the configured timeout period, the service scales back to zero.

### Managing JIT Services

Service status:
```bash
/opt/bin/jit-services.sh status
```

Start a service:
```bash
/opt/bin/jit-services.sh start mealie_mealie
```

Stop a service:
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

### Tailscale

For secure remote access I deploy Tailscale as a subnet router:
```bash
ssh core@192.168.99.101
cd ~/flatcar-swarm-homelab
./scripts/setup-tailscale-secrets.sh
```

Generate a reusable auth key in the Tailscale admin console with these settings enabled:
- Reusable
- Pre-authorized  
- Tagged (use `tag:homelab`)

The stack deploys three instances (one per manager) for redundancy. After deployment, enable subnet routes and exit node in Tailscale admin console for each node.

### AdGuard Home

This is pre-configured with my preferred settings, including encrypted upstream DNS, block lists, and DNS rewrites for local services. Modify to your tastes.

Configure credentials before deployment:
```bash
./scripts/setup-adguard-secrets.sh
```

## Monitoring and Observability

Prometheus collects metrics from all nodes and services. Grafana provides dashboards for visualization. I put together my own custom dashboard for the things I want to see, but if you know Grafana you know there's tons of dashboards you can import. Again, modify to your tastes. 

The monitoring stack includes:

- Node exporter for system metrics (CPU, memory, disk)
- cAdvisor for container metrics
- Prometheus with 7-day retention
- Grafana with custom Swarm dashboard
- Alertmanager with ntfy.sh integration for push notifications

Access Grafana at `http://grafana.local` (default credentials: admin/admin).

## Backup and Recovery

I wanted distributed storage so if a node goes offline I don't lose data. I'm not hosting large databases and am not storing huge quantities of data, but I wanted to learn distributed storage. _Unfortunately_, a true solution like GlusterFS doesn't run on Pis with Flatcar and Swarm network overlays. So I went with MinIO on a single node with replication to volumes on the other nodes. For this purpose, the cluster initialiization includes all nodes generating and swapping their own SSH keys. Backups run daily at 2 AM, automatically starting MinIO if needed, backing up all critical volumes, and scaling MinIO back down after completion.

Volume locations:
- Docker volumes: `/var/lib/docker/volumes`
- Stack configurations: `/home/core/flatcar-swarm-homelab`

Create a backup manually:
```bash
sudo systemctl start minio-backup.service
```

Backups are stored in the MinIO `backups` bucket. Access the MinIO console at `http://minio.local` with credentials from `~/.minio-password`.

## Maintenance

### View Logs
```bash
# Service logs
docker service logs -f monitoring_prometheus

# Bootstrap logs  
journalctl -u swarm-bootstrap.service

# Automated deployment logs
sudo journalctl -u git-poll.service -f
```

### Updating Services

Modify the YAML and redeploy:
```bash
docker stack deploy -c stacks/SERVICE/SERVICE-stack.yml SERVICE
```

Docker Swarm performs rolling updates automatically.

### Adding Nodes

Flash Flatcar to an SDcard with the script, boot the node, and it joins automatically. Verify with `docker node ls`.

### Removing Nodes

Drain services from the node:
```bash
docker node update --availability drain NODE_ID
```

Wait for services to migrate, then leave the swarm:
```bash
docker swarm leave  # Run on the node being removed
docker node rm NODE_ID  # Run from a manager
```

## Troubleshooting

### Node Won't Join Swarm

Check bootstrap logs:
```bash
journalctl -u swarm-bootstrap.service
```

Verify network connectivity to the primary manager:
```bash
ping 192.168.99.101
curl http://192.168.99.101:8080/manager-token
```

Check that `/etc/environment` has the correct `SWARM_PRIMARY_MANAGER_IP`.

### Service Won't Start
```bash
docker service ps SERVICE_NAME
docker service logs SERVICE_NAME
docker service inspect SERVICE_NAME
```
### Traefik Routing Problems

Check the Traefik dashboard at `http://traefik.local`. Verify service labels in the stack YAML match Traefik's format. Ensure services are on the `traefik-public` network.

## What I've Learned

Building this cluster taught me a lot about container orchestration. The constraint of Pis with limited RAM forced me to think carefully about resource allocation and service lifecycle management. Automating the entire deployment from scratch gave me some good exposure to continuous deployment in practice.

The JIT system ended up being more to chew on than I expected, and I ended up leaning into AI more heavily to try to close the gap between basic understanding and functional code, but I believe I have a good enough grasp on enough to give me a head start if/when I need to implement such a system in future projects. 

The biggest lesson: distributed systems are hard, and building in observability and automated recovery from the start saves time troubleshooting later.

## Next Steps

This homelab serves its purpose as a learning environment, and I'll continue to run and maintain this cluster, but I really hope to have the resources to get my hands dirty with Kubernetes down the road. I should be able to translate the concepts and workflows I've learned to a k3s or k8s cluster. I know there's much, much more to learn about networking and security that the Docker ecosystem just isn't going to teach me. I'm also particularly looking forward to getting better acquainted with Flux or ArgoCD for CI/CD with Kubernetes. The git-poll approach I have here works fine for this cluster, but I recognize it's not _proper_ tooling and doesn't provide the same capabilities.

## License

MIT License. Use this however you'd like. If it helps you learn something, great!
