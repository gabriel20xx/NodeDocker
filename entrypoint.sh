#!/bin/bash
set -euo pipefail

echo "[entrypoint] Starting unified NodeDocker bootstrap"

### Primary repo clone ###
# Effective primary repo/branch (new names override legacy)
PRIMARY_REPO=${PRIMARY_GIT_REPO:-${PRIMARY_REPO:-${GIT_REPO:-}}}
PRIMARY_BRANCH=${PRIMARY_GIT_BRANCH:-${PRIMARY_BRANCH:-${GIT_BRANCH:-}}}
if [ -z "${PRIMARY_REPO:-}" ]; then
  echo "Error: Primary repo not set. Provide PRIMARY_REPO (or legacy GIT_REPO)." >&2
  exit 1
fi
# Clone the primary repo directly into /app so that subfolders are /app/NudeForge and /app/NudeFlow
PRIMARY_DIR="/app"

if [[ "$PRIMARY_REPO" == git@* ]]; then
  CLONE_METHOD="ssh"
elif [[ "$PRIMARY_REPO" == https://* ]]; then
  CLONE_METHOD="https"
else
  echo "Error: GIT_REPO must start with https:// or git@" >&2
  exit 1
fi

if [ "$CLONE_METHOD" = "https" ] && [ -n "${PRIMARY_TOKEN:-}" ]; then
  AUTH_REPO=${PRIMARY_REPO/https:\/\//https://$PRIMARY_TOKEN@}
else
  AUTH_REPO="$PRIMARY_REPO"
fi

echo "[entrypoint] Ensuring $PRIMARY_DIR exists"
mkdir -p "$PRIMARY_DIR"
chown -R 99:100 "/app" || true
chmod -R 777 "/app" || true

if [ -d "$PRIMARY_DIR/.git" ]; then
  echo "[entrypoint] Updating existing repo in $PRIMARY_DIR..."
  (cd "$PRIMARY_DIR" && git fetch --depth=1 origin ${PRIMARY_BRANCH:-} || true && \
    if [ -n "$PRIMARY_BRANCH" ]; then git reset --hard "origin/$PRIMARY_BRANCH"; else git reset --hard "FETCH_HEAD"; fi) || \
    echo "[entrypoint] Warning: repo update failed; proceeding with existing contents"
else
  if [ -n "$PRIMARY_BRANCH" ]; then
    echo "[entrypoint] Cloning primary repo branch '$PRIMARY_BRANCH' into $PRIMARY_DIR..."
    git clone --depth=1 --branch "$PRIMARY_BRANCH" "$AUTH_REPO" "$PRIMARY_DIR"
  else
    echo "[entrypoint] Cloning primary repo default branch into $PRIMARY_DIR..."
    git clone --depth=1 "$AUTH_REPO" "$PRIMARY_DIR"
  fi
fi

chown -R 99:100 "$PRIMARY_DIR" || true
chmod -R 777 "$PRIMARY_DIR" || true

# Determine which app to run and enter its directory
PROJECT_TYPE="${FORCE_PROJECT_TYPE:-}"
if [ -z "$PROJECT_TYPE" ]; then
  if [ -f "/app/NudeForge/src/services/carousel.js" ] || [ -d "/app/NudeForge/src/public/images/carousel" ]; then
    PROJECT_TYPE="NudeForge"
  elif [ -f "/app/NudeFlow/src/utils/AppUtils.js" ] || [ -f "/app/NudeFlow/src/app.js" ]; then
    PROJECT_TYPE="NudeFlow"
  else
    PROJECT_TYPE="Unknown"
  fi
fi
APP_DIR="/app/$PROJECT_TYPE"
if [ ! -d "$APP_DIR/src" ]; then
  echo "[entrypoint] Error: Could not locate app directory at $APP_DIR/src" >&2
  ls -la /app || true
  exit 1
fi
echo "[entrypoint] Detected project type: $PROJECT_TYPE"
cd "$APP_DIR"

# Ensure environment points to shared source path unless already provided
export NUDESHARED_DIR="${NUDESHARED_DIR:-/app/NudeShared/src}"
echo "[entrypoint] Using NUDESHARED_DIR=$NUDESHARED_DIR"

# Default data directories to root-level mounts if not provided
export INPUT_DIR="${INPUT_DIR:-/input}"
export OUTPUT_DIR="${OUTPUT_DIR:-/output}"
export UPLOAD_COPY_DIR="${UPLOAD_COPY_DIR:-/copy}"
export LORAS_DIR="${LORAS_DIR:-/loras}"
echo "[entrypoint] Data dirs: INPUT_DIR=$INPUT_DIR OUTPUT_DIR=$OUTPUT_DIR UPLOAD_COPY_DIR=$UPLOAD_COPY_DIR LORAS_DIR=$LORAS_DIR"

### Shared (secondary) repo clone (NudeShared or custom) ###
# Environment overrides (new names override legacy):
#   SECONDARY_REPO or SECONDARY_GIT_REPO (falls back to NUDESHARED_REPO; default: https://github.com/gabriel20xx/NudeShared.git)
#   SECONDARY_BRANCH or SECONDARY_GIT_BRANCH (falls back to NUDESHARED_BRANCH; default: master)
#   NUDESHARED_DIR (default: /app/NudeShared/src)
#   NUDESHARED_SKIP (if set to 'true' skip cloning)

if [ "${NUDESHARED_SKIP:-false}" != "true" ]; then
  EFFECTIVE_SHARED_REPO=${SECONDARY_GIT_REPO:-${SECONDARY_REPO:-${NUDESHARED_REPO:-"https://github.com/gabriel20xx/NudeShared.git"}}}
  EFFECTIVE_SHARED_BRANCH=${SECONDARY_GIT_BRANCH:-${SECONDARY_BRANCH:-${NUDESHARED_BRANCH:-"master"}}}
  # Default to /app/NudeShared/src so other code can rely on this path
  NUDESHARED_DIR=${NUDESHARED_DIR:-"/app/NudeShared/src"}
  echo "[entrypoint] Preparing shared repo (repo=$EFFECTIVE_SHARED_REPO branch=$EFFECTIVE_SHARED_BRANCH dir=$NUDESHARED_DIR)"

  AUTH_SHARED="$EFFECTIVE_SHARED_REPO"
  if [[ "$EFFECTIVE_SHARED_REPO" == https://github.com/* ]] && [[ "$EFFECTIVE_SHARED_REPO" != *"@github.com"* ]] && [ -n "${SECONDARY_TOKEN:-}" ]; then
    AUTH_SHARED=${EFFECTIVE_SHARED_REPO/https:\/\//https://$SECONDARY_TOKEN@}
  fi

  # Ensure parent folder exists (e.g., /app/NudeShared)
  mkdir -p "$(dirname "$NUDESHARED_DIR")"
  if [ ! -d "$NUDESHARED_DIR/.git" ]; then
    echo "[entrypoint] Cloning shared repo into $NUDESHARED_DIR"
    git clone --depth=1 --branch "$EFFECTIVE_SHARED_BRANCH" "$AUTH_SHARED" "$NUDESHARED_DIR" || echo "[entrypoint] Warning: failed to clone shared repo"
  else
    echo "[entrypoint] Updating shared repo in $NUDESHARED_DIR"
    (cd "$NUDESHARED_DIR" && git fetch --depth=1 origin "$EFFECTIVE_SHARED_BRANCH" && git reset --hard "origin/$EFFECTIVE_SHARED_BRANCH" || echo "[entrypoint] Warning: failed to update shared repo")
  fi
else
  echo "[entrypoint] Skipping shared repo clone (NUDESHARED_SKIP=true)"
fi

### Sync shared assets (theme.css, logger.js) for NudeForge or NudeFlow ###
SHARED_SRC_DIR=${NUDESHARED_DIR:-/app/NudeShared/src}
THEME_SRC="$SHARED_SRC_DIR/theme.css"
LOGGER_SRC="$SHARED_SRC_DIR/logger.js"

DEST_THEME="src/public/css/theme.css"
DEST_LOGGER="src/utils/logger.js"  # logger may be a dynamic loader; copy only if file exists in shared

if [ -d src/public/css ]; then
  mkdir -p src/public/css
  if [ -f "$THEME_SRC" ]; then
    echo "[entrypoint] Syncing theme.css -> $DEST_THEME"
    cp -f "$THEME_SRC" "$DEST_THEME" || echo "[entrypoint] Warning: failed to copy theme.css"
  else
    echo "[entrypoint] Warning: theme.css not found in shared repo"
  fi
fi

if [ -d src/utils ]; then
  mkdir -p src/utils
  if [ -f "$LOGGER_SRC" ]; then
    # Only overwrite if destination empty or contains placeholder comment
    if ! grep -q "Robust shared logger" "$DEST_LOGGER" 2>/dev/null; then
      echo "[entrypoint] Syncing logger.js -> $DEST_LOGGER (non-robust version)"
      cp -f "$LOGGER_SRC" "$DEST_LOGGER" || echo "[entrypoint] Warning: failed to copy logger.js"
    else
      echo "[entrypoint] Detected enhanced local logger loader; skip overwrite"
    fi
  else
    echo "[entrypoint] Warning: logger.js not found in shared repo"
  fi
fi

### Install dependencies ###
INSTALL_CMD=${NPM_INSTALL_CMD:-"npm install"}
echo "[entrypoint] Installing dependencies ($INSTALL_CMD)"
sh -c "$INSTALL_CMD"

### Project-specific setup (only for NudeForge) ###
if [ "$PROJECT_TYPE" = "NudeForge" ]; then
  if [ "${SKIP_CAROUSEL_SETUP:-false}" != "true" ]; then
    echo "[entrypoint][forge] Ensuring carousel directories"
    mkdir -p src/public/images/carousel/thumbnails
    chmod 755 src/public/images/carousel/thumbnails 2>/dev/null || true
  fi
  if [ "${REBUILD_SHARP:-true}" = "true" ]; then
    if grep -q '"sharp"' package.json 2>/dev/null; then
      echo "[entrypoint][forge] Rebuilding sharp"
      (npm rebuild sharp || echo "[entrypoint][forge] Warning: sharp rebuild failed")
    fi
  fi
fi

### Optional build step ###
if [ -n "${BUILD_CMD:-}" ]; then
  echo "[entrypoint] Running build step: $BUILD_CMD"
  sh -c "$BUILD_CMD"
fi

### Start application ###
START_CMD=${START_CMD:-"npm start"}
echo "[entrypoint] Launching application: $START_CMD"
exec sh -c "$START_CMD"
