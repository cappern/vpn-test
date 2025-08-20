#!/usr/bin/env bash
# Simple smoke tests for vpn-probe container
set -euo pipefail

IMAGE_TAG="vpn-probe:test"

echo "Building image..."
docker build -t "$IMAGE_TAG" .

echo "Ensuring missing env var causes failure..."
OUTPUT=$(docker run --rm "$IMAGE_TAG" 2>&1 || true)
echo "$OUTPUT" | grep -q "Missing VPN_URL"

echo "Ensuring openconnect is available..."
docker run --rm --entrypoint openconnect "$IMAGE_TAG" --version >/dev/null

echo "All tests passed."
