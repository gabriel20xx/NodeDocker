#!/bin/bash
set -euo pipefail

echo "[entrypoint] Starting unified NodeDocker bootstrap"

### Primary repo clone ###
if [ -z "${GIT_REPO:-}" ]; then
  echo "Error: GIT_REPO environment variable is not set." >&2
  exit 1
fi

PRIMARY_BRANCH=${GIT_BRANCH:-}
PRIMARY_DIR=/app

if [[ "$GIT_REPO" == git@* ]]; then
  CLONE_METHOD="ssh"
elif [[ "$GIT_REPO" == https://* ]]; then
  CLONE_METHOD="https"
else
  echo "Error: GIT_REPO must start with https:// or git@" >&2
  exit 1
fi

if [ "$CLONE_METHOD" = "https" ] && [ -n "${GIT_TOKEN:-}" ]; then
  AUTH_REPO=${GIT_REPO/https:\/\//https://$GIT_TOKEN@}
else
  AUTH_REPO="$GIT_REPO"
fi

echo "[entrypoint] Resetting $PRIMARY_DIR"
rm -rf "$PRIMARY_DIR"
mkdir -p "$PRIMARY_DIR"
chown -R 99:100 "$PRIMARY_DIR" || true
chmod -R 777 "$PRIMARY_DIR" || true

if [ -n "$PRIMARY_BRANCH" ]; then
  echo "[entrypoint] Cloning primary repo branch '$PRIMARY_BRANCH'..."
  git clone --depth=1 --branch "$PRIMARY_BRANCH" "$AUTH_REPO" "$PRIMARY_DIR"
else
  echo "[entrypoint] Cloning primary repo default branch..."
  git clone --depth=1 "$AUTH_REPO" "$PRIMARY_DIR"
fi

chown -R 99:100 "$PRIMARY_DIR" || true
chmod -R 777 "$PRIMARY_DIR" || true

cd "$PRIMARY_DIR"

### Shared (secondary) repo clone (NudeShared or custom) ###
# Environment overrides:
#   NUDESHARED_REPO (default: https://github.com/gabriel20xx/NudeShared.git)
#   NUDESHARED_BRANCH (default: master)
#   NUDESHARED_DIR (default: /app/NudeShared)
#   NUDESHARED_SKIP (if set to 'true' skip cloning)

if [ "${NUDESHARED_SKIP:-false}" != "true" ]; then
  NUDESHARED_REPO=${NUDESHARED_REPO:-"https://github.com/gabriel20xx/NudeShared.git"}
  NUDESHARED_BRANCH=${NUDESHARED_BRANCH:-"master"}
  NUDESHARED_DIR=${NUDESHARED_DIR:-"/app/NudeShared"}
  echo "[entrypoint] Preparing shared repo (repo=$NUDESHARED_REPO branch=$NUDESHARED_BRANCH dir=$NUDESHARED_DIR)"

  AUTH_SHARED="$NUDESHARED_REPO"
  if [[ "$NUDESHARED_REPO" == https://github.com/* ]] && [[ "$NUDESHARED_REPO" != *"@github.com"* ]] && [ -n "${GITHUB_TOKEN:-}" ]; then
    AUTH_SHARED=${NUDESHARED_REPO/https:\/\//https://$GITHUB_TOKEN@}
  fi

  if [ ! -d "$NUDESHARED_DIR/.git" ]; then
    git clone --depth=1 --branch "$NUDESHARED_BRANCH" "$AUTH_SHARED" "$NUDESHARED_DIR" || echo "[entrypoint] Warning: failed to clone shared repo"
  else
    (cd "$NUDESHARED_DIR" && git fetch --depth=1 origin "$NUDESHARED_BRANCH" && git reset --hard "origin/$NUDESHARED_BRANCH" || echo "[entrypoint] Warning: failed to update shared repo")
  fi
else
  echo "[entrypoint] Skipping shared repo clone (NUDESHARED_SKIP=true)"
fi

### Sync shared assets (theme.css, logger.js) for NudeForge or NudeFlow ###
SHARED_SRC_DIR=${NUDESHARED_DIR:-/app/NudeShared}
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

### Project-specific detection & setup (NudeForge vs NudeFlow) ###
PROJECT_TYPE="${FORCE_PROJECT_TYPE:-}"
if [ -z "$PROJECT_TYPE" ]; then
  if [ -f src/services/carousel.js ] || [ -d src/public/images/carousel ]; then
    PROJECT_TYPE="NudeForge"
  elif [ -f src/utils/AppUtils.js ]; then
    PROJECT_TYPE="NudeFlow"
  else
    PROJECT_TYPE="Unknown"
  fi
fi
echo "[entrypoint] Detected project type: $PROJECT_TYPE"

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
