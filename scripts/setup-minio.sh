#!/bin/bash
# Setup MinIO distributed storage and test resource usage

set -e

echo "=== MinIO Distributed Storage Setup ==="
echo ""

# Generate strong password if not set
if [ -z "$MINIO_ROOT_PASSWORD" ]; then
    MINIO_ROOT_PASSWORD=$(openssl rand -base64 32)
    echo "Generated MinIO password: $MINIO_ROOT_PASSWORD"
    echo "IMPORTANT: Save this password!"
    echo ""
fi

# Store password as Docker secret
echo "$MINIO_ROOT_PASSWORD" | docker secret create minio_root_password - 2>/dev/null || \
    echo "Secret already exists, using existing password"

# Update stack file with secret reference
sed -i 's/${MINIO_ROOT_PASSWORD}/\/run\/secrets\/minio_root_password/' \
    stacks/minio/minio-stack.yml || true

echo "Deploying MinIO..."
docker stack deploy -c stacks/minio/minio-stack.yml minio

echo ""
echo "Waiting for services to start (60s)..."
sleep 60

echo ""
echo "=== Testing Resource Usage ==="
docker stats --no-stream $(docker ps -q -f name=minio)

echo ""
echo "=== MinIO Status ==="
docker service ps minio_minio

echo ""
echo "=== Access MinIO ==="
echo "Console: http://minio.local (or http://192.168.99.101:9001)"
echo "S3 API:  http://s3.local (or http://192.168.99.101:9000)"
echo ""
echo "Username: minioadmin"
echo "Password: $MINIO_ROOT_PASSWORD"
echo ""
echo "Test with mc (MinIO client):"
echo "  docker run --rm -it --network minio_storage-net minio/mc:latest \\"
echo "    mc alias set myminio http://swarm-manager-1:9000 minioadmin '$MINIO_ROOT_PASSWORD'"
echo "  docker run --rm -it --network minio_storage-net minio/mc:latest \\"
echo "    mc mb myminio/test-bucket"
echo ""
