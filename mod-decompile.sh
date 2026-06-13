#!/usr/bin/env bash
# mod-decompile.sh — decompile a NeoForge mod JAR and scaffold an MDK project
# Usage: ./mod-decompile.sh <mod.jar> [mc-version]
# mc-version defaults to 1.21.1
set -euo pipefail

JAR="${1:-}"
MC_VERSION="${2:-1.21.1}"

if [[ -z "$JAR" || ! -f "$JAR" ]]; then
  echo "Usage: $0 <mod.jar> [mc-version]" >&2
  exit 1
fi

JAR="$(realpath "$JAR")"
MOD_NAME="$(basename "$JAR" .jar)"
OUT_DIR="$(pwd)/${MOD_NAME}-src"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/mod-decompile"
mkdir -p "$CACHE_DIR"

echo "==> JAR:        $JAR"
echo "==> MC version: $MC_VERSION"
echo "==> Output:     $OUT_DIR"
echo ""

# ---- 1. Vineflower ----
VF_JAR="$CACHE_DIR/vineflower.jar"
if [[ ! -f "$VF_JAR" ]]; then
  echo "==> Downloading Vineflower..."
  VF_URL="$(curl -fsSL https://api.github.com/repos/Vineflower/vineflower/releases/latest \
    | grep '"browser_download_url"' \
    | grep '\.jar"' \
    | head -1 \
    | sed 's/.*"browser_download_url": "\(.*\)"/\1/')"
  curl -fSL -o "$VF_JAR" "$VF_URL"
  echo "    saved to $VF_JAR"
fi

# ---- 2. Decompile ----
echo "==> Decompiling..."
DECOMPILED="$CACHE_DIR/${MOD_NAME}-decompiled"
rm -rf "$DECOMPILED"
java -jar "$VF_JAR" "$JAR" "$DECOMPILED" 2>&1 | grep -v "^$" | sed 's/^/    /'
echo "    done"

# ---- 3. Parse mod metadata ----
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
rm -f "$TOML_TMP"

MOD_ID="${MOD_ID:-modid}"
MOD_VERSION="${MOD_VERSION:-1.0.0}"
echo "    modId:   $MOD_ID"
echo "    version: $MOD_VERSION"

# ---- 4. Resolve NeoForge version ----
echo "==> Resolving NeoForge version for MC $MC_VERSION..."
NF_PREFIX="${MC_VERSION#1.}"          # "1.21.1" -> "21.1"
MAVEN_META="$(curl -fsSL "https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml")"
NF_VERSION="$(echo "$MAVEN_META" \
  | grep "<version>${NF_PREFIX}\." \
  | sed 's|.*<version>\(.*\)</version>.*|\1|' \
  | sort -t. -k3 -n \
  | tail -1 \
  | tr -d '[:space:]')"

if [[ -z "$NF_VERSION" ]]; then
  echo "    ERROR: could not find a NeoForge version for MC $MC_VERSION" >&2
  exit 1
fi
echo "    NeoForge $NF_VERSION"

# ---- 5. Download MDK from NeoForge GitHub template ----
# NeoForge no longer ships an MDK zip on maven; use the GitHub template repo.
# Branch naming: MC 1.21.1 -> try "archive/1.21.1", then "archive/1.21", then "main".
MC_MINOR="${MC_VERSION%.*}"     # "1.21.1" -> "1.21"
MDK_BRANCH=""
for branch_try in "archive/${MC_VERSION#1.}" "archive/${MC_MINOR#1.}" "main"; do
  status="$(curl -fsSL -o /dev/null -w "%{http_code}" \
    "https://github.com/neoforged/MDK/archive/refs/heads/${branch_try}.zip" 2>/dev/null || true)"
  if [[ "$status" == "200" || "$status" == "302" ]]; then
    MDK_BRANCH="$branch_try"
    break
  fi
done
MDK_BRANCH="${MDK_BRANCH:-main}"
echo "    MDK branch: $MDK_BRANCH"

MDK_ZIP="$CACHE_DIR/neoforge-mdk-${MDK_BRANCH//\//-}.zip"
if [[ ! -f "$MDK_ZIP" ]]; then
  echo "==> Downloading MDK..."
  curl -fSL -o "$MDK_ZIP" \
    "https://github.com/neoforged/MDK/archive/refs/heads/${MDK_BRANCH}.zip"
fi

# ---- 6. Extract MDK and scaffold project ----
echo "==> Setting up project at $OUT_DIR..."
rm -rf "$OUT_DIR"
unzip -q "$MDK_ZIP" -d "$OUT_DIR"
# MDK zips have a top-level dir (MDK-<branch>), flatten it
TOP="$(ls "$OUT_DIR")"
if [[ "$(echo "$TOP" | wc -l)" -eq 1 && -d "$OUT_DIR/$TOP" ]]; then
  mv "$OUT_DIR/$TOP"/* "$OUT_DIR/"
  rmdir "$OUT_DIR/$TOP"
fi

# ---- 7. Copy decompiled sources ----
echo "==> Copying sources..."
SRC_JAVA="$OUT_DIR/src/main/java"
SRC_RES="$OUT_DIR/src/main/resources"
mkdir -p "$SRC_JAVA" "$SRC_RES"

# Java sources
find "$DECOMPILED" -name "*.java" | while read -r f; do
  rel="${f#$DECOMPILED/}"
  dest="$SRC_JAVA/$rel"
  mkdir -p "$(dirname "$dest")"
  cp "$f" "$dest"
done

# Resources (non-class, non-java files from the JAR)
RESOURCES_TMP="$(mktemp -d)"
unzip -q "$JAR" -d "$RESOURCES_TMP"
find "$RESOURCES_TMP" -not -name "*.class" -not -name "*.java" -type f | while read -r f; do
  rel="${f#$RESOURCES_TMP/}"
  [[ "$rel" == META-INF/MANIFEST.MF ]] && continue
  [[ "$rel" == META-INF/*.SF ]] && continue
  [[ "$rel" == META-INF/*.RSA ]] && continue
  dest="$SRC_RES/$rel"
  mkdir -p "$(dirname "$dest")"
  cp "$f" "$dest"
done
rm -rf "$RESOURCES_TMP"

# ---- 8. Access transformer ----
AT_DEST="$SRC_RES/META-INF/accesstransformer.cfg"
if [[ -f "$AT_DEST" ]]; then
  echo "==> Found accesstransformer.cfg — wiring it up in build.gradle..."
  if ! grep -q "accessTransformer" "$OUT_DIR/build.gradle" 2>/dev/null; then
    sed -i '/^minecraft {/a\\taccessTransformer = file("src/main/resources/META-INF/accesstransformer.cfg")' \
      "$OUT_DIR/build.gradle" 2>/dev/null || true
  fi
fi

# ---- 9. Patch gradle.properties ----
echo "==> Patching gradle.properties..."
PROPS="$OUT_DIR/gradle.properties"
sed -i "s/^mod_id\s*=.*/mod_id=${MOD_ID}/"               "$PROPS" 2>/dev/null || true
sed -i "s/^mod_version\s*=.*/mod_version=${MOD_VERSION}/" "$PROPS" 2>/dev/null || true
sed -i "s/^neo_version\s*=.*/neo_version=${NF_VERSION}/"   "$PROPS" 2>/dev/null || true
sed -i "s/^minecraft_version\s*=.*/minecraft_version=${MC_VERSION}/" "$PROPS" 2>/dev/null || true

echo ""
echo "==> Done! Project at: $OUT_DIR"
echo ""
echo "    Next steps:"
echo "    1. cd $OUT_DIR"
echo "    2. Review src/main/java/ — fix decompiler artifacts as needed"
echo "    3. Add any missing mod deps to build.gradle"
echo "    4. ./gradlew build"
echo "    5. JAR lands in build/libs/"
