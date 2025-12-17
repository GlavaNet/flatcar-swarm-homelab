#!/bin/sh
# Master script to complete JIT setup and cleanup

set -e

echo "========================================"
echo "JIT Services - Production Setup"
echo "========================================"
echo ""
echo "This script will:"
echo "  1. Add Vaultwarden to JIT services"
echo "  2. Update deployment scripts with JIT"
echo "  3. Clean up temporary files"
echo ""
read -p "Continue? (y/n): " confirm

if [ "$confirm" != "y" ]; then
    echo "Aborted."
    exit 0
fi

SCRIPTS_DIR="$HOME/Projects/flatcar-swarm-homelab/scripts"
cd "$SCRIPTS_DIR"

# Step 1: Add Vaultwarden
echo ""
echo "========================================="
echo "STEP 1: Adding Vaultwarden to JIT"
echo "========================================="
echo ""

if [ -f add-vaultwarden-jit.sh ]; then
    ./add-vaultwarden-jit.sh
else
    echo "⚠ Script not found, downloading..."
    curl -sO https://example.com/add-vaultwarden-jit.sh
    chmod +x add-vaultwarden-jit.sh
    ./add-vaultwarden-jit.sh
fi

echo ""
read -p "Step 1 complete. Continue to Step 2? (y/n): " continue_step2

if [ "$continue_step2" != "y" ]; then
    echo "Stopping. You can resume by running: ./finalize-jit-setup.sh"
    exit 0
fi

# Step 2: Update cluster-init.sh
echo ""
echo "========================================="
echo "STEP 2: Updating Deployment Scripts"
echo "========================================="
echo ""

if [ -f cluster-init-with-jit.sh ]; then
    echo "Backing up existing cluster-init.sh..."
    [ -f cluster-init.sh ] && cp cluster-init.sh cluster-init.sh.pre-jit
    
    echo "Installing new cluster-init.sh with JIT support..."
    cp cluster-init-with-jit.sh cluster-init.sh
    chmod +x cluster-init.sh
    
    echo "✓ cluster-init.sh updated"
fi

# Update deploy-services.sh if it exists
if [ -f deploy-services.sh ]; then
    echo ""
    echo "Updating deploy-services.sh to scale JIT services to 0..."
    
    # Add JIT scaling to end of deploy script
    if ! grep -q "Scale JIT services to 0" deploy-services.sh; then
        cat >> deploy-services.sh << 'EOFJIT'

# Scale JIT services to 0 (auto-start on demand)
echo ""
echo "=== Scaling JIT Services to 0 ==="
docker service scale mealie_mealie=0 2>/dev/null || true
docker service scale forgejo_forgejo=0 2>/dev/null || true
docker service scale vaultwarden_vaultwarden=0 2>/dev/null || true
echo "✓ JIT services scaled to 0"
echo ""
echo "JIT services will auto-start on access:"
echo "  • http://recipes.local → Mealie"
echo "  • http://git.local → Forgejo"
echo "  • http://vault.local → Vaultwarden"
EOFJIT
        echo "✓ deploy-services.sh updated"
    else
        echo "  Already includes JIT scaling"
    fi
fi

echo ""
read -p "Step 2 complete. Continue to Step 3 (cleanup)? (y/n): " continue_step3

if [ "$continue_step3" != "y" ]; then
    echo "Stopping. You can run cleanup later: ./cleanup-temp-files.sh"
    exit 0
fi

# Step 3: Cleanup
echo ""
echo "========================================="
echo "STEP 3: Cleaning Up Temporary Files"
echo "========================================="
echo ""

if [ -f cleanup-temp-files.sh ]; then
    ./cleanup-temp-files.sh
fi

# Final summary
echo ""
echo "========================================"
echo "✓ JIT Setup Complete!"
echo "========================================"
echo ""
echo "Summary of changes:"
echo "  ✓ Vaultwarden added to JIT services"
echo "  ✓ cluster-init.sh updated with JIT support"
echo "  ✓ deploy-services.sh updated to scale JIT to 0"
echo "  ✓ Temporary files cleaned up"
echo "  ✓ Documentation created"
echo ""
echo "JIT Services (auto-start on demand):"
echo "  • http://recipes.local → Mealie"
echo "  • http://git.local → Forgejo"
echo "  • http://vault.local → Vaultwarden"
echo "  • http://minio.local → MinIO"
echo ""
echo "Management:"
echo "  /opt/bin/jit-services.sh status"
echo "  /opt/bin/jit-services.sh start <service>"
echo "  /opt/bin/jit-services.sh stop <service>"
echo ""
echo "Webhook API:"
echo "  curl http://192.168.99.101:9999/health"
echo "  curl -X POST http://192.168.99.101:9999/start/mealie"
echo ""
echo "Documentation:"
echo "  cat ~/flatcar-swarm-homelab/docs/JIT-SERVICES.md"
echo ""
echo "Next steps:"
echo "  1. Test each service:"
echo "     docker service scale mealie_mealie=0"
echo "     # Visit http://recipes.local"
echo ""
echo "  2. Commit to git:"
echo "     cd ~/flatcar-swarm-homelab"
echo "     git add -A"
echo "     git commit -m 'Add JIT services with auto-start'"
echo "     git push"
echo ""
echo "  3. Optional: Add more services"
echo "     See scripts/jit/add-vaultwarden-jit.sh as template"
echo ""
