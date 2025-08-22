#!/bin/bash
set -euo pipefail
cd / || {
  echo "[entrypoint] Fatal: cannot cd to root" >&2
  exit 1
}

echo "[entrypoint] Starting unified NodeDocker bootstrap"

### Primary repo clone ###
# Require explicit PRIMARY_REPO; branch optional (default branch if empty)
PRIMARY_REPO=${PRIMARY_REPO:-}
PRIMARY_BRANCH=${PRIMARY_BRANCH:-}
if [ -z "${PRIMARY_REPO}" ]; then
  echo "Error: PRIMARY_REPO environment variable is not set." >&2
  exit 1
fi
# Clone target: prefer staging dir when /app already has content that isn't a git repo
PRIMARY_DIR="/app"
if [ ! -d "/app/.git" ]; then
  if [ -n "$(ls -A /app 2>/dev/null || true)" ]; then
    PRIMARY_DIR="/app/_primary"
  fi
fi

if [[ "$PRIMARY_REPO" == git@* ]]; then
  CLONE_METHOD="ssh"
elif [[ "$PRIMARY_REPO" == https://* ]]; then
  CLONE_METHOD="https"
else
  echo "Error: PRIMARY_REPO must start with https:// or git@" >&2
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

# If we cloned/updated into a staging dir, normalize layout so src lives under /app/<ProjectName>/src for single-app repos
if [ "$PRIMARY_DIR" != "/app" ]; then
  if [ -d "$PRIMARY_DIR/NudeForge/src" ] || [ -d "$PRIMARY_DIR/NudeFlow/src" ]; then
    echo "[entrypoint] Detected monorepo layout in $PRIMARY_DIR; syncing into /app"
    # Copy everything into /app, preserving structure
    cp -a "$PRIMARY_DIR"/. /app/
    rm -rf "$PRIMARY_DIR"
  elif [ -d "$PRIMARY_DIR/src" ]; then
    echo "[entrypoint] Detected single-app layout in $PRIMARY_DIR; relocating under /app/<ProjectName>"
    # Decide destination folder name
    DEST_NAME="${FORCE_PROJECT_TYPE:-}"
    if [ -z "$DEST_NAME" ]; then
      if [ -f "$PRIMARY_DIR/package.json" ]; then
        DEST_NAME=$(node -e "try{console.log(require(process.argv[1]).name||'')}catch{console.log('')}" "$PRIMARY_DIR/package.json") || DEST_NAME=""
      fi
    fi
    if [ -z "$DEST_NAME" ]; then
      # Fallback to repo basename
      BASENAME=$(basename "$PRIMARY_REPO")
      DEST_NAME=${BASENAME%.git}
    fi
    # Sanitize name (no slashes, spaces)
    DEST_NAME=${DEST_NAME//\//}
    DEST_NAME=${DEST_NAME// /_}
    [ -z "$DEST_NAME" ] && DEST_NAME="App"
    DEST_DIR="/app/$DEST_NAME"
    echo "[entrypoint] Relocating to $DEST_DIR"
    rm -rf "$DEST_DIR"
    mkdir -p "$DEST_DIR"
    cp -a "$PRIMARY_DIR"/. "$DEST_DIR"/
    rm -rf "$PRIMARY_DIR"
    export FORCE_PROJECT_TYPE="$DEST_NAME"
  else
    echo "[entrypoint] Warning: No src directory found in $PRIMARY_DIR; syncing contents to /app as-is"
    cp -a "$PRIMARY_DIR"/. /app/
    rm -rf "$PRIMARY_DIR"
  fi
fi

# If we cloned directly into /app and it's a single-app layout, relocate to /app/<ProjectName>
if [ "$PRIMARY_DIR" = "/app" ] && [ -d "/app/src" ]; then
  echo "[entrypoint] Detected single-app layout in /app; relocating under /app/<ProjectName>"
  DEST_NAME="${FORCE_PROJECT_TYPE:-}"
  if [ -z "$DEST_NAME" ] && [ -f "/app/package.json" ]; then
    DEST_NAME=$(node -e "try{console.log(require(process.argv[1]).name||'')}catch{console.log('')}" "/app/package.json") || DEST_NAME=""
  fi
  if [ -z "$DEST_NAME" ]; then
    BASENAME=$(basename "$PRIMARY_REPO")
    DEST_NAME=${BASENAME%.git}
  fi
  DEST_NAME=${DEST_NAME//\//}
  DEST_NAME=${DEST_NAME// /_}
  [ -z "$DEST_NAME" ] && DEST_NAME="App"
  DEST_DIR="/app/$DEST_NAME"
  echo "[entrypoint] Relocating to $DEST_DIR"
  rm -rf "$DEST_DIR"
  mkdir -p "$DEST_DIR"
  # Copy everything except the destination dir itself (handles dotfiles too)
  for item in /app/* /app/.*; do
    base=$(basename "$item")
    if [ "$base" = "." ] || [ "$base" = ".." ]; then
      continue
    fi
    if [ "$base" = "$(basename "$DEST_DIR")" ]; then
      continue
    fi
    [ -e "$item" ] || continue
    cp -a "$item" "$DEST_DIR"/
  done
  # Remove all except the destination dir
  for item in /app/* /app/.*; do
    base=$(basename "$item")
    if [ "$base" != "$(basename "$DEST_DIR")" ] && [ "$base" != "." ] && [ "$base" != ".." ]; then
      rm -rf "$item"
    fi
  done
  export FORCE_PROJECT_TYPE="$DEST_NAME"
fi

# Determine which app to run and enter its directory
PROJECT_TYPE="${FORCE_PROJECT_TYPE:-}"
if [ -z "$PROJECT_TYPE" ]; then
  if [ -f "/app/NudeForge/src/services/carousel.js" ] || [ -d "/app/NudeForge/src/public/images/carousel" ]; then
    PROJECT_TYPE="NudeForge"
    APP_DIR="/app/NudeForge"
  elif [ -f "/app/NudeFlow/src/utils/AppUtils.js" ] || [ -f "/app/NudeFlow/src/app.js" ]; then
    PROJECT_TYPE="NudeFlow"
    APP_DIR="/app/NudeFlow"
  elif [ -d "/app/src" ]; then
    # Repo is the app root directly under /app
    APP_DIR="/app"
    # Try to infer type from package.json name (optional)
    if [ -f "/app/package.json" ]; then
      PKG_NAME=$(node -e "try{console.log(require('/app/package.json').name||'')}catch{console.log('')}") || PKG_NAME=""
      case "$PKG_NAME" in
        nudeforge) PROJECT_TYPE="NudeForge" ;;
        nudeflow) PROJECT_TYPE="NudeFlow" ;;
        *) PROJECT_TYPE="Unknown" ;;
      esac
    else
      PROJECT_TYPE="Unknown"
    fi
  else
    PROJECT_TYPE="Unknown"
    APP_DIR="/app"
  fi
else
  APP_DIR="/app/$PROJECT_TYPE"
fi

# If a forced project type points to a non-existent app dir but /app/src exists, fall back to /app
if [ ! -d "$APP_DIR/src" ] && [ -d "/app/src" ]; then
  echo "[entrypoint] Note: $APP_DIR/src not found; falling back to /app"
  APP_DIR="/app"
  # Try to infer type from package.json name (optional)
  if [ -f "/app/package.json" ]; then
    PKG_NAME=$(node -e "try{console.log(require('/app/package.json').name||'')}catch{console.log('')}") || PKG_NAME=""
    case "$PKG_NAME" in
      nudeforge) PROJECT_TYPE="NudeForge" ;;
      nudeflow) PROJECT_TYPE="NudeFlow" ;;
      *) PROJECT_TYPE="Unknown" ;;
    esac
  else
    PROJECT_TYPE="Unknown"
  fi
fi

if [ ! -d "$APP_DIR/src" ]; then
  echo "[entrypoint] Warning: Expected src directory not found at $APP_DIR/src; listing /app for diagnostics:" >&2
  ls -la /app || true
fi
echo "[entrypoint] Detected project type: $PROJECT_TYPE (APP_DIR=$APP_DIR)"
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
# Require explicit SECONDARY_REPO unless SECONDARY_SKIP=true; branch optional

if [ "${SECONDARY_SKIP:-false}" != "true" ]; then
  if [ -z "${SECONDARY_REPO:-}" ]; then
    echo "Error: SECONDARY_REPO environment variable is not set (or set SECONDARY_SKIP=true)." >&2
    exit 1
  fi
  SECONDARY_BRANCH=${SECONDARY_BRANCH:-}
  # Compute shared dir from repo name (override with NUDESHARED_DIR if provided)
  SHARED_BASENAME=$(basename "${SECONDARY_REPO}")
  SHARED_NAME=${SHARED_BASENAME%.git}
  DEFAULT_SHARED_DIR="/app/${SHARED_NAME}/src"
  NUDESHARED_DIR=${NUDESHARED_DIR:-"$DEFAULT_SHARED_DIR"}
  echo "[entrypoint] Preparing shared repo (repo=$SECONDARY_REPO branch=${SECONDARY_BRANCH:-<default>} dir=$NUDESHARED_DIR)"

  AUTH_SHARED="$SECONDARY_REPO"
  if [[ "$SECONDARY_REPO" == https://github.com/* ]] && [[ "$SECONDARY_REPO" != *"@github.com"* ]] && [ -n "${SECONDARY_TOKEN:-}" ]; then
    AUTH_SHARED=${SECONDARY_REPO/https:\/\//https://$SECONDARY_TOKEN@}
  fi

  # Ensure parent folder exists (e.g., /app/NudeShared)
  mkdir -p "$(dirname "$NUDESHARED_DIR")"
  if [ ! -d "$NUDESHARED_DIR/.git" ]; then
    echo "[entrypoint] Cloning shared repo into $NUDESHARED_DIR"
    if [ -n "$SECONDARY_BRANCH" ]; then
      git clone --depth=1 --branch "$SECONDARY_BRANCH" "$AUTH_SHARED" "$NUDESHARED_DIR" || echo "[entrypoint] Warning: failed to clone shared repo"
    else
      git clone --depth=1 "$AUTH_SHARED" "$NUDESHARED_DIR" || echo "[entrypoint] Warning: failed to clone shared repo"
    fi
  else
    echo "[entrypoint] Updating shared repo in $NUDESHARED_DIR"
    (cd "$NUDESHARED_DIR" && git fetch --depth=1 origin ${SECONDARY_BRANCH:-} || true && \
      if [ -n "$SECONDARY_BRANCH" ]; then git reset --hard "origin/$SECONDARY_BRANCH"; else git reset --hard "FETCH_HEAD"; fi) || \
      echo "[entrypoint] Warning: failed to update shared repo"
  fi
else
  echo "[entrypoint] Skipping shared repo clone (SECONDARY_SKIP=true)"
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
