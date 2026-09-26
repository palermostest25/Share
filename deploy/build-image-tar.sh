#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
SERVER_DIR="$PROJECT_DIR/server"
OUTPUT="$PROJECT_DIR/Share-server-1.3.1-linux-amd64.tar"
BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/share-image.XXXXXX")
trap 'rm -rf "$BUILD_DIR"' EXIT HUP INT TERM

cd "$SERVER_DIR"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w -X main.version=1.3.1" -o "$BUILD_DIR/nasdrive" .

mkdir -p "$BUILD_DIR/rootfs" "$BUILD_DIR/archive/layer"
cp "$BUILD_DIR/nasdrive" "$BUILD_DIR/rootfs/nasdrive"
chmod 0755 "$BUILD_DIR/rootfs/nasdrive"
tar --format=ustar --owner=0 --group=0 -C "$BUILD_DIR/rootfs" -cf "$BUILD_DIR/archive/layer/layer.tar" nasdrive

LAYER_SHA=$(shasum -a 256 "$BUILD_DIR/archive/layer/layer.tar" | awk '{print $1}')
CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
sed -e "s/CREATED_VALUE/$CREATED/g" -e "s/LAYER_SHA_VALUE/$LAYER_SHA/g" "$SCRIPT_DIR/image-config.template.json" > "$BUILD_DIR/config.json"
CONFIG_SHA=$(shasum -a 256 "$BUILD_DIR/config.json" | awk '{print $1}')
mv "$BUILD_DIR/config.json" "$BUILD_DIR/archive/$CONFIG_SHA.json"
sed -e "s/CONFIG_SHA_VALUE/$CONFIG_SHA/" "$SCRIPT_DIR/image-manifest.template.json" > "$BUILD_DIR/archive/manifest.json"
printf '1.0' > "$BUILD_DIR/archive/layer/VERSION"
cp "$SCRIPT_DIR/image-layer.template.json" "$BUILD_DIR/archive/layer/json"
tar --format=ustar -C "$BUILD_DIR/archive" -cf "$OUTPUT" .
echo "$OUTPUT"
