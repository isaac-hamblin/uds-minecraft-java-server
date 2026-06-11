#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALUES_FILE="${ROOT_DIR}/values/common-values.yaml"
BUILD_DIR="${ROOT_DIR}/.build/minecraft"
CREATE_PACKAGE="true"
PACKAGE_OPTIONS=""
PLATFORM="linux/amd64"
ARCHITECTURE="amd64"

usage() {
  cat <<'EOF'
Usage: scripts/build-minecraft-zarf.sh [options]

Builds the pinned Minecraft Java server image from values/common-values.yaml.
This script does not modify tracked package files.

Options:
  --skip-package          Build only the container image
  --package-options <str> Extra options passed to `zarf package create`
  --platform <platform>   Docker platform to build (default: linux/amd64)
  --architecture <arch>   Zarf package architecture (default: amd64)
  -h, --help              Show this help

Requirements:
  curl, docker, shasum, yq, zarf
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-package) CREATE_PACKAGE="false"; shift ;;
    --package-options) PACKAGE_OPTIONS="${2:-}"; shift 2 ;;
    --platform) PLATFORM="${2:-}"; shift 2 ;;
    --architecture) ARCHITECTURE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

for bin in curl docker shasum yq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Missing required tool: $bin"; exit 1; }
done

if [[ "$CREATE_PACKAGE" == "true" ]]; then
  command -v zarf >/dev/null 2>&1 || { echo "Missing required tool: zarf"; exit 1; }
fi

MC_VERSION="$(yq -r '.minecraft.version' "$VALUES_FILE")"
JAVA_MAJOR="$(yq -r '.minecraft.javaMajor' "$VALUES_FILE")"
SERVER_URL="$(yq -r '.minecraft.serverJar.url' "$VALUES_FILE")"
SERVER_SHA1="$(yq -r '.minecraft.serverJar.sha1' "$VALUES_FILE")"
SERVER_SHA256="$(yq -r '.minecraft.serverJar.sha256' "$VALUES_FILE")"
IMAGE_REPOSITORY="$(yq -r '.image.repository' "$VALUES_FILE")"
IMAGE_TAG="$(yq -r '.image.tag' "$VALUES_FILE")"
IMG_NAME="${IMAGE_REPOSITORY}:${IMAGE_TAG}"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "[build] Minecraft version: ${MC_VERSION} (Java ${JAVA_MAJOR})"
echo "[build] Downloading pinned server jar..."
curl -fsSL "$SERVER_URL" -o "$BUILD_DIR/server.jar"

echo "[build] Verifying SHA1 and SHA256..."
printf '%s  %s\n' "$SERVER_SHA1" "$BUILD_DIR/server.jar" | shasum -a 1 -c -
printf '%s  %s\n' "$SERVER_SHA256" "$BUILD_DIR/server.jar" | shasum -a 256 -c -

cat > "$BUILD_DIR/entrypoint.sh" <<'EOS'
#!/usr/bin/env sh
set -eu

DATA_DIR="${DATA_DIR:-/data}"
JAR_PATH="/opt/minecraft/server.jar"

mkdir -p "$DATA_DIR"

if [ ! -f "$DATA_DIR/eula.txt" ]; then
  if [ "${EULA:-}" != "TRUE" ] && [ "${EULA:-}" != "true" ]; then
    echo "[minecraft] You must accept the Minecraft EULA by setting EULA=TRUE"
    exit 1
  fi
  echo "eula=true" > "$DATA_DIR/eula.txt"
fi

if [ ! -f "$DATA_DIR/server.properties" ]; then
  if [ -n "${SERVER_PROPERTIES:-}" ]; then
    printf '%s\n' "$SERVER_PROPERTIES" > "$DATA_DIR/server.properties"
  else
    ONLINE_MODE="${ONLINE_MODE:-false}"
    cat > "$DATA_DIR/server.properties" <<EOF
server-port=25565
online-mode=${ONLINE_MODE}
motd=UDS Minecraft Server
enable-rcon=false
EOF
  fi
fi

JAVA_OPTS="${JAVA_OPTS:-}"
if [ -n "${MEMORY:-}" ]; then
  JAVA_OPTS="$JAVA_OPTS -Xms${MEMORY} -Xmx${MEMORY}"
fi

cd "$DATA_DIR"
exec java $JAVA_OPTS -jar "$JAR_PATH" nogui
EOS
chmod +x "$BUILD_DIR/entrypoint.sh"

cat > "$BUILD_DIR/Dockerfile" <<EOF
FROM eclipse-temurin:${JAVA_MAJOR}-jre
WORKDIR /opt/minecraft
COPY server.jar /opt/minecraft/server.jar
COPY entrypoint.sh /entrypoint.sh
EXPOSE 25565/tcp
VOLUME ["/data"]
ENTRYPOINT ["/entrypoint.sh"]
EOF

echo "[build] Building Docker image: ${IMG_NAME}"
docker build --platform "$PLATFORM" -t "$IMG_NAME" "$BUILD_DIR"
docker image inspect "$IMG_NAME" >/dev/null

if [[ "$CREATE_PACKAGE" == "true" ]]; then
  echo "[build] Creating Zarf package..."
  # shellcheck disable=SC2086
  (cd "$ROOT_DIR" && zarf package create . --confirm --architecture "$ARCHITECTURE" $PACKAGE_OPTIONS)
fi

echo "[ok] Built image: ${IMG_NAME}"
