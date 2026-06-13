#!/usr/bin/env bash
# mod-patch-gradle.sh — patch gradle.properties in an existing mod project
# Usage: ./mod-patch-gradle.sh <mod.jar> [project-dir] [mc-version]
set -euo pipefail

JAR="${1:-}"
MC_VERSION="${3:-1.21.1}"

if [[ -z "$JAR" || ! -f "$JAR" ]]; then
  echo "Usage: $0 <mod.jar> [project-dir] [mc-version]" >&2
  exit 1
fi

JAR="$(realpath "$JAR")"
MOD_NAME="$(basename "$JAR" .jar)"
PROJECT_DIR="${2:-$(pwd)/${MOD_NAME}-src}"

if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "ERROR: project dir not found: $PROJECT_DIR" >&2
  exit 1
fi

PROPS="$PROJECT_DIR/gradle.properties"
echo "==> JAR:     $JAR"
echo "==> Project: $PROJECT_DIR"
echo ""

# Parse mod metadata from JAR
echo "==> Reading mod metadata..."
TOML_TMP="$(mktemp)"
unzip -p "$JAR" "META-INF/neoforge.mods.toml" > "$TOML_TMP" 2>/dev/null \
  || unzip -p "$JAR" "META-INF/mods.toml" > "$TOML_TMP" 2>/dev/null \
  || { echo "    WARNING: no mods.toml found in JAR"; touch "$TOML_TMP"; }

extract_toml() {
  local key="$1"
  grep -m1 "^${key}\s*=" "$TOML_TMP" 2>/dev/null \
    | sed 's/.*=\s*"\(.*\)".*/\1/' \
    | tr -d '\r' \
    || true
}

MOD_ID="$(extract_toml modId)"
MOD_VERSION="$(extract_toml version)"
MOD_DESC="$(extract_toml description)"
rm -f "$TOML_TMP"

MOD_ID="${MOD_ID:-modid}"
MOD_VERSION="${MOD_VERSION:-1.0.0}"
echo "    modId:   $MOD_ID"
echo "    version: $MOD_VERSION"

# Resolve NeoForge version
echo "==> Resolving NeoForge version for MC $MC_VERSION..."
NF_PREFIX="${MC_VERSION#1.}"
MAVEN_META="$(curl -fsSL "https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml")"
NF_VERSION="$(echo "$MAVEN_META" \
  | grep "<version>${NF_PREFIX}\." \
  | sed 's|.*<version>\(.*\)</version>.*|\1|' \
  | sort -t. -k3 -n \
  | tail -1 \
  | tr -d '[:space:]')"

if [[ -z "$NF_VERSION" ]]; then
  echo "    ERROR: could not find NeoForge version for MC $MC_VERSION" >&2
  exit 1
fi
echo "    NeoForge $NF_VERSION"

# Detect actual mod group ID from source package declarations
MOD_GROUP_ID="com.example.${MOD_ID}"
JAVA_FILE="$(find "$PROJECT_DIR/src/main/java" -name "*.java" -type f 2>/dev/null | head -1)"
if [[ -n "$JAVA_FILE" ]]; then
  PKG="$(grep -m1 '^package ' "$JAVA_FILE" 2>/dev/null | sed 's/^package //;s/;//' | tr -d '[:space:]')"
  [[ -n "$PKG" ]] && MOD_GROUP_ID="$PKG" && echo "    detected group: $MOD_GROUP_ID"
fi

# Write or patch gradle.properties
echo "==> Patching $PROPS..."
if [[ -f "$PROPS" ]]; then
  sed -i "s/^mod_id\s*=.*/mod_id=${MOD_ID}/"               "$PROPS"
  sed -i "s/^mod_version\s*=.*/mod_version=${MOD_VERSION}/" "$PROPS"
  sed -i "s/^neo_version\s*=.*/neo_version=${NF_VERSION}/"  "$PROPS"
  sed -i "s/^minecraft_version\s*=.*/minecraft_version=${MC_VERSION}/" "$PROPS"
  sed -i "s/^mod_group_id\s*=.*/mod_group_id=${MOD_GROUP_ID}/" "$PROPS"
  # Add missing keys if not present
  grep -q "^minecraft_version_range" "$PROPS" || echo "minecraft_version_range=[${MC_VERSION},)" >> "$PROPS"
  grep -q "^neo_version_range"       "$PROPS" || echo "neo_version_range=[${NF_VERSION},)"       >> "$PROPS"
  grep -q "^loader_version_range"    "$PROPS" || echo "loader_version_range=[1,)"                >> "$PROPS"
  grep -q "^mod_name"                "$PROPS" || echo "mod_name=${MOD_ID}"                       >> "$PROPS"
  grep -q "^mod_license"             "$PROPS" || echo "mod_license=ARR"                          >> "$PROPS"
  grep -q "^mod_description"         "$PROPS" || echo "mod_description=${MOD_DESC:-Decompiled mod}" >> "$PROPS"
  grep -q "^mod_authors"             "$PROPS" || echo "mod_authors=Unknown"                      >> "$PROPS"
  grep -q "^pack_format_number"      "$PROPS" || echo "pack_format_number=34"                    >> "$PROPS"
else
  cat > "$PROPS" <<PROPS_EOF
org.gradle.jvmargs=-Xmx3G
org.gradle.daemon=false
minecraft_version=${MC_VERSION}
minecraft_version_range=[${MC_VERSION},)
neo_version=${NF_VERSION}
neo_version_range=[${NF_VERSION},)
loader_version_range=[1,)
mod_id=${MOD_ID}
mod_name=${MOD_ID}
mod_group_id=${MOD_GROUP_ID}
mod_license=ARR
mod_version=${MOD_VERSION}
mod_description=${MOD_DESC:-Decompiled mod}
mod_authors=Unknown
pack_format_number=34
PROPS_EOF
fi

echo "    done"
echo ""
echo "==> gradle.properties updated at $PROPS"
