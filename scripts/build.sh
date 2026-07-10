#!/bin/bash
# Build the agrun image and remove stale container

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONTAINER_NAME="agrun"

echo "Building image..."
docker build -t agrun "$PROJECT_DIR" || exit 1

# Remove old container so run.sh creates a fresh one from the new image
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Removing old container..."
    docker rm -f "$CONTAINER_NAME" > /dev/null
fi
