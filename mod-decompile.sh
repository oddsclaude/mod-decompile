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
MOD_DESC="$(extract_toml description)"

# Extract mandatory dependency modIds (skip neoforge/minecraft/forge/java)
DEP_IDS=()
while IFS= read -r dep_id; do
  [[ "$dep_id" =~ ^(neoforge|minecraft|forge|java)$ ]] && continue
  [[ -z "$dep_id" ]] && continue
  DEP_IDS+=("$dep_id")
done < <(grep -A5 '^\[\[dependencies\.' "$TOML_TMP" \
         | grep 'modId\s*=' \
         | sed 's/.*=\s*"\(.*\)".*/\1/' \
         | sort -u | tr -d '\r')

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
# Try both "archive/1.X.Y" and "archive/X.Y" naming conventions.
MC_MINOR="${MC_VERSION%.*}"     # "1.21.1" -> "1.21"
MDK_BRANCH=""
for branch_try in \
    "archive/${MC_VERSION}" \
    "archive/${MC_VERSION#1.}" \
    "archive/${MC_MINOR}" \
    "archive/${MC_MINOR#1.}" \
    "main"; do
  status="$(curl -o /dev/null -sLw "%{http_code}" \
    "https://github.com/neoforged/MDK/archive/refs/heads/${branch_try}.zip" 2>/dev/null || true)"
  if [[ "$status" == "200" || "$status" == "301" || "$status" == "302" ]]; then
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
# MDK zips have a top-level dir (MDK-<branch>), flatten it (cp -a handles dotfiles)
TOP="$(ls "$OUT_DIR")"
if [[ "$(echo "$TOP" | wc -l)" -eq 1 && -d "$OUT_DIR/$TOP" ]]; then
  cp -a "$OUT_DIR/$TOP"/. "$OUT_DIR/"
  rm -rf "$OUT_DIR/$TOP"
fi

# ---- 6b. Generate build files if MDK didn't provide them ----
if [[ ! -f "$OUT_DIR/gradle.properties" ]]; then
  echo "==> MDK had no build files — generating Gradle scaffold for NeoForge ${NF_VERSION}..."

  cat > "$OUT_DIR/settings.gradle" <<'SETTINGS_EOF'
pluginManagement {
    repositories {
        maven { url = 'https://maven.neoforged.net/releases' }
        gradlePluginPortal()
    }
}
SETTINGS_EOF

  cat > "$OUT_DIR/build.gradle" <<'BUILD_EOF'
plugins {
    id 'net.neoforged.gradle.userdev' version '7.0.145'
}

version = project.mod_version
group = "com.example.${project.mod_id}"
base { archivesName = project.mod_id }
java.toolchain.languageVersion = JavaLanguageVersion.of(21)

runs {
    client { client() }
    server { server(); programArgument '--nogui' }
}

dependencies {
    implementation "net.neoforged:neoforge:${project.neo_version}"
}
BUILD_EOF

  mkdir -p "$OUT_DIR/gradle/wrapper"
  # gradle.properties with resolved values
  cat > "$OUT_DIR/gradle.properties" <<PROPS_EOF
org.gradle.jvmargs=-Xmx3G
org.gradle.daemon=false
minecraft_version=${MC_VERSION}
neo_version=${NF_VERSION}
mod_id=${MOD_ID}
mod_version=${MOD_VERSION}
PROPS_EOF

  cat > "$OUT_DIR/gradle/wrapper/gradle-wrapper.properties" <<'WRAPPER_EOF'
distributionBase=GRADLE_USER_HOME
distributionPath=wrapper/dists
distributionUrl=https\://services.gradle.org/distributions/gradle-8.8-bin.zip
zipStoreBase=GRADLE_USER_HOME
zipStorePath=wrapper/dists
WRAPPER_EOF

  curl -fsSL -o "$OUT_DIR/gradlew" \
    "https://raw.githubusercontent.com/neoforged/MDK/main/gradlew" 2>/dev/null || \
    echo "    WARNING: could not fetch gradlew — run 'gradle wrapper --gradle-version=8.8' to generate"
  chmod +x "$OUT_DIR/gradlew" 2>/dev/null || true
  curl -fsSL -o "$OUT_DIR/gradle/wrapper/gradle-wrapper.jar" \
    "https://raw.githubusercontent.com/neoforged/MDK/main/gradle/wrapper/gradle-wrapper.jar" 2>/dev/null || \
    echo "    WARNING: could not fetch gradle-wrapper.jar — run 'gradle wrapper --gradle-version=8.8' to regenerate"

  echo "    generated settings.gradle, build.gradle, gradle.properties, gradlew"
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
  # skip META-INF/MANIFEST.MF and signing artifacts
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
sed -i "s/^mod_id\s*=.*/mod_id=${MOD_ID}/"           "$PROPS" 2>/dev/null || true
sed -i "s/^mod_version\s*=.*/mod_version=${MOD_VERSION}/" "$PROPS" 2>/dev/null || true
sed -i "s/^neo_version\s*=.*/neo_version=${NF_VERSION}/" "$PROPS" 2>/dev/null || true
sed -i "s/^minecraft_version\s*=.*/minecraft_version=${MC_VERSION}/" "$PROPS" 2>/dev/null || true

# ---- 10. Resolve and inject mod dependencies ----
if [[ ${#DEP_IDS[@]} -gt 0 ]]; then
  echo "==> Resolving ${#DEP_IDS[@]} mod dep(s) via Modrinth: ${DEP_IDS[*]}"
  NEED_MR_REPO=false
  NEED_CF_REPO=false
  DEP_INJECT=""

  for dep in "${DEP_IDS[@]}"; do
    MR_URL="https://api.modrinth.com/v2/project/${dep}/version?game_versions=%5B%22${MC_VERSION}%22%5D&loaders=%5B%22neoforge%22%5D"
    MR_RESP="$(curl -fsSL "$MR_URL" 2>/dev/null || echo "[]")"
    VER_ID="$(printf '%s' "$MR_RESP" | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//;s/"//')"

    if [[ -n "$VER_ID" ]]; then
      echo "    $dep -> maven.modrinth:${dep}:${VER_ID}"
      DEP_INJECT="${DEP_INJECT}    runtimeOnly \"maven.modrinth:${dep}:${VER_ID}\"\n"
      NEED_MR_REPO=true
    else
      echo "    $dep -> not found on Modrinth (add manually)"
      DEP_INJECT="${DEP_INJECT}    // TODO: ${dep} not on Modrinth — try: curse.maven:${dep}-<projectId>:<fileId>\n"
      NEED_CF_REPO=true
    fi
  done

  # Inject deps after first "dependencies {" line
  if [[ -f "$OUT_DIR/build.gradle" && -n "$DEP_INJECT" ]]; then
    awk -v inject="$(printf '%b' "$DEP_INJECT")" \
      '/^dependencies \{/{print; print inject; next} 1' \
      "$OUT_DIR/build.gradle" > "$OUT_DIR/build.gradle.tmp" && \
      mv "$OUT_DIR/build.gradle.tmp" "$OUT_DIR/build.gradle"
  fi

  # Add maven repos block before dependencies block
  if $NEED_MR_REPO || $NEED_CF_REPO; then
    REPO_LINES="repositories {"
    $NEED_MR_REPO && REPO_LINES="${REPO_LINES}\n    maven { url = 'https://api.modrinth.com/maven' }"
    $NEED_CF_REPO && REPO_LINES="${REPO_LINES}\n    maven { url = 'https://www.cursemaven.com' }"
    REPO_LINES="${REPO_LINES}\n}"
    awk -v repos="$(printf '%b' "$REPO_LINES")" \
      '/^dependencies \{/{print repos; print ""; print; next} 1' \
      "$OUT_DIR/build.gradle" > "$OUT_DIR/build.gradle.tmp" && \
      mv "$OUT_DIR/build.gradle.tmp" "$OUT_DIR/build.gradle"
  fi
fi

echo ""
echo "==> Done! Project at: $OUT_DIR"
echo ""
echo "    Next steps:"
echo "    1. cd $OUT_DIR"
echo "    2. Review src/main/java/ — fix decompiler artifacts as needed"
echo "    3. Add any missing mod deps to build.gradle"
echo "    4. ./gradlew build"
echo "    5. JAR lands in build/libs/"
