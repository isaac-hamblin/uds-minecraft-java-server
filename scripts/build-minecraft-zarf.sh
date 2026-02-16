#!/usr/bin/env bash
set -euo pipefail

# --- Config / Args ------------------------------------------------------------
MODE="release"      # release | snapshot
TAG="latest"        # image tag to build/package
MC_VERSION=""       # optional override version like 1.21.4
DO_UDS_CREATE="false"

usage() {
  cat <<'EOF'
Usage: scripts/build-minecraft-zarf.sh [options]

Options:
  --snapshot              Use latest snapshot instead of latest release
  --version <id>          Use a specific Minecraft version id (e.g. 1.21.4)
  --tag <tag>             Docker image tag to build (default: latest)
  --uds-create            Also run `uds create .` after building the zarf package

Requirements:
  curl, jq, sha1sum, docker, zarf
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --snapshot) MODE="snapshot"; shift ;;
    --version)  MC_VERSION="${2:-}"; shift 2 ;;
    --tag)      TAG="${2:-}"; shift 2 ;;
    --uds-create) DO_UDS_CREATE="true"; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

for bin in curl jq sha1sum docker zarf; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Missing required tool: $bin"; exit 1; }
done

MANIFEST_URL="https://launchermeta.mojang.com/mc/game/version_manifest.json"

# --- Resolve version + download URLs -----------------------------------------
echo "[build] Fetching Mojang version manifest..."
manifest_json="$(curl -fsSL "$MANIFEST_URL")"

if [[ -z "${MC_VERSION}" ]]; then
  if [[ "$MODE" == "snapshot" ]]; then
    MC_VERSION="$(jq -r '.latest.snapshot' <<<"$manifest_json")"
  else
    MC_VERSION="$(jq -r '.latest.release' <<<"$manifest_json")"
  fi
fi

version_url="$(jq -r --arg v "$MC_VERSION" '.versions[] | select(.id == $v) | .url' <<<"$manifest_json")"
if [[ -z "$version_url" || "$version_url" == "null" ]]; then
  echo "[error] Could not find version URL for version id: $MC_VERSION"
  exit 1
fi

echo "[build] Resolving version metadata for $MC_VERSION..."
ver_json="$(curl -fsSL "$version_url")"

server_url="$(jq -r '.downloads.server.url' <<<"$ver_json")"
server_sha1="$(jq -r '.downloads.server.sha1' <<<"$ver_json")"
java_major="$(jq -r '.javaVersion.majorVersion // 21' <<<"$ver_json")"

if [[ -z "$server_url" || "$server_url" == "null" ]]; then
  echo "[error] Could not find downloads.server.url in version metadata"
  exit 1
fi

echo "[build] Latest selected version: $MC_VERSION (Java $java_major)"
echo "[build] Server URL: $server_url"

# --- Build context ------------------------------------------------------------
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/minecraft"
IMG_NAME="minecraft-java-server:${TAG}"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "[build] Downloading server.jar..."
curl -fsSL "$server_url" -o "$BUILD_DIR/server.jar"

echo "[build] Verifying SHA1..."
echo "${server_sha1}  $BUILD_DIR/server.jar" | sha1sum -c -

cat > "$BUILD_DIR/entrypoint.sh" <<'EOS'
#!/usr/bin/env sh
set -eu

DATA_DIR="${DATA_DIR:-/data}"
JAR_PATH="/opt/minecraft/server.jar"

mkdir -p "$DATA_DIR"

# Require explicit EULA acceptance.
# Users can set EULA=TRUE in the Deployment.
if [ ! -f "$DATA_DIR/eula.txt" ]; then
  if [ "${EULA:-}" != "TRUE" ] && [ "${EULA:-}" != "true" ]; then
    echo "[minecraft] You must accept the Minecraft EULA by setting EULA=TRUE"
    echo "[minecraft] (This script will then write eula=true into $DATA_DIR/eula.txt)"
    exit 1
  fi
  echo "eula=true" > "$DATA_DIR/eula.txt"
fi

# Create a minimal server.properties if one doesn't exist yet.
# For truly air-gapped environments, online-mode typically needs to be false.
if [ ! -f "$DATA_DIR/server.properties" ]; then
  ONLINE_MODE="${ONLINE_MODE:-false}"
  MOTD="${MOTD:-UDS Minecraft Server}"
  cat > "$DATA_DIR/server.properties" <<EOF
server-port=25565
online-mode=${ONLINE_MODE}
motd=${MOTD}
enable-rcon=false
EOF
fi

# Memory: honor MEMORY like "2G" if provided
JAVA_OPTS="${JAVA_OPTS:-}"
if [ -n "${MEMORY:-}" ]; then
  JAVA_OPTS="$JAVA_OPTS -Xms${MEMORY} -Xmx${MEMORY}"
fi

cd "$DATA_DIR"
exec java $JAVA_OPTS -jar "$JAR_PATH" nogui
EOS
chmod +x "$BUILD_DIR/entrypoint.sh"

cat > "$BUILD_DIR/Dockerfile" <<EOF
FROM eclipse-temurin:${java_major}-jre
WORKDIR /opt/minecraft
COPY server.jar /opt/minecraft/server.jar
COPY entrypoint.sh /entrypoint.sh
EXPOSE 25565/tcp
VOLUME ["/data"]
ENTRYPOINT ["/entrypoint.sh"]
EOF

# --- Build image --------------------------------------------------------------
echo "[build] Building Docker image: $IMG_NAME"
docker build --platform linux/amd64 -t "$IMG_NAME" "$BUILD_DIR"
docker image inspect "$IMG_NAME" >/dev/null

# --- Patch repo references (optional but convenient) --------------------------
DEPLOY_YAML="$ROOT_DIR/manifests/deployment.yaml"
ZARF_YAML="$ROOT_DIR/zarf.yaml"

echo "[build] Ensuring manifests reference image: $IMG_NAME"

if [[ -f "$DEPLOY_YAML" ]]; then
  # Replace itzg reference if present, otherwise replace first 'image:' under containers.
  if grep -q "itzg/minecraft-server" "$DEPLOY_YAML"; then
    sed -i -E "s#image:\s*itzg/minecraft-server:.*#image: ${IMG_NAME}#g" "$DEPLOY_YAML"
  else
    # Best-effort: replace any minecraft-java image line
    sed -i -E "s#image:\s*minecraft-java-server:.*#image: ${IMG_NAME}#g" "$DEPLOY_YAML" || true
  fi
fi

if [[ -f "$ZARF_YAML" ]]; then
  if grep -q "itzg/minecraft-server" "$ZARF_YAML"; then
    sed -i -E "s#- \"?itzg/minecraft-server:.*\"?#- \"${IMG_NAME}\"#g" "$ZARF_YAML"
  else
    sed -i -E "s#- \"?minecraft-java-server:.*\"?#- \"${IMG_NAME}\"#g" "$ZARF_YAML" || true
  fi
fi

# --- Create Zarf package ------------------------------------------------------
echo "[build] Creating Zarf package..."
(
  cd "$ROOT_DIR"
  zarf package create . --confirm
)

echo ""
echo "[ok] Built server version: $MC_VERSION"
echo "[ok] Built image: $IMG_NAME"
echo "[ok] Zarf package should now exist in this directory."
echo ""

# --- Optionally create UDS bundle artifact -----------------------------------
if [[ "$DO_UDS_CREATE" == "true" ]]; then
  command -v uds >/dev/null 2>&1 || { echo "Missing required tool for --uds-create: uds"; exit 1; }
  echo "[build] Creating UDS bundle artifact..."
  ( cd "$ROOT_DIR" && uds create . --confirm )
  echo "[ok] UDS bundle artifact created."
fi

