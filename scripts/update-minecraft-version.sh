#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION=""
UDS_REVISION="0"
MANIFEST_URL="https://launchermeta.mojang.com/mc/game/version_manifest.json"

usage() {
  cat <<'EOF'
Usage: scripts/update-minecraft-version.sh [options]

Updates pinned Minecraft version metadata in chart and package files.
This is the explicit "latest" workflow; normal builds use committed pins.

Options:
  --version <id>          Minecraft version id to pin
  --uds-revision <n>      UDS package revision suffix (default: 0)
  -h, --help              Show this help

Requirements:
  curl, jq, shasum, yq
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --uds-revision) UDS_REVISION="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

for bin in curl jq shasum yq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Missing required tool: $bin"; exit 1; }
done

echo "[update] Fetching Mojang version manifest..."
manifest_json="$(curl -fsSL "$MANIFEST_URL")"

if [[ -z "$VERSION" ]]; then
  VERSION="$(jq -r '.latest.release' <<<"$manifest_json")"
fi

version_url="$(jq -r --arg v "$VERSION" '.versions[] | select(.id == $v) | .url' <<<"$manifest_json")"
if [[ -z "$version_url" || "$version_url" == "null" ]]; then
  echo "[error] Could not find version URL for version id: $VERSION"
  exit 1
fi

echo "[update] Resolving metadata for ${VERSION}..."
version_json="$(curl -fsSL "$version_url")"
server_url="$(jq -r '.downloads.server.url' <<<"$version_json")"
server_sha1="$(jq -r '.downloads.server.sha1' <<<"$version_json")"
java_major="$(jq -r '.javaVersion.majorVersion // 21' <<<"$version_json")"

if [[ -z "$server_url" || "$server_url" == "null" ]]; then
  echo "[error] Version ${VERSION} does not include a server jar"
  exit 1
fi

tmpfile="$(mktemp /tmp/minecraft-server.XXXXXX)"
trap 'rm -f "$tmpfile"' EXIT

echo "[update] Downloading server jar to compute SHA256..."
curl -fsSL "$server_url" -o "$tmpfile"
printf '%s  %s\n' "$server_sha1" "$tmpfile" | shasum -a 1 -c -
server_sha256="$(shasum -a 256 "$tmpfile" | awk '{print $1}')"

package_version="${VERSION}-uds.${UDS_REVISION}"

for values_file in "${ROOT_DIR}/values/common-values.yaml" "${ROOT_DIR}/chart/values.yaml"; do
  yq -i ".image.tag = \"${VERSION}\"" "$values_file"
  yq -i ".minecraft.version = \"${VERSION}\"" "$values_file"
  yq -i ".minecraft.javaMajor = ${java_major}" "$values_file"
  yq -i ".minecraft.serverJar.url = \"${server_url}\"" "$values_file"
  yq -i ".minecraft.serverJar.sha1 = \"${server_sha1}\"" "$values_file"
  yq -i ".minecraft.serverJar.sha256 = \"${server_sha256}\"" "$values_file"
done

yq -i ".appVersion = \"${VERSION}\"" "${ROOT_DIR}/chart/Chart.yaml"
yq -i ".metadata.version = \"${package_version}\"" "${ROOT_DIR}/zarf.yaml"
yq -i ".components[0].images = [\"minecraft-java-server:${VERSION}\"]" "${ROOT_DIR}/zarf.yaml"
yq -i ".metadata.version = \"${package_version}\"" "${ROOT_DIR}/bundle/uds-bundle.yaml"
yq -i "(.packages[] | select(.name == \"minecraft-java\").ref) = \"${package_version}\"" "${ROOT_DIR}/bundle/uds-bundle.yaml"

echo "[ok] Updated Minecraft to ${VERSION}"
echo "[ok] Package version: ${package_version}"
echo "[ok] Server SHA256: ${server_sha256}"
