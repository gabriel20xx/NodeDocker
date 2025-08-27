#!/bin/sh
set -e

# --- Config (minimal) ---
# Main app repo (e.g., gabriel20xx/NudeForge or gabriel20xx/NudeFlow)
APP_REPO="${APP_REPO:-gabriel20xx/NudeForge}"
APP_BASENAME="$(echo "$APP_REPO" | awk -F/ '{print $NF}')"
APP_DIR="/app/$APP_BASENAME"

# Secondary repo (default: NudeShared)
SECONDARY_REPO="${SECONDARY_REPO:-gabriel20xx/NudeShared}"
SECONDARY_BASENAME="$(echo "$SECONDARY_REPO" | awk -F/ '{print $NF}')"
SECONDARY_DIR="/app/$SECONDARY_BASENAME"

# GitHub token (required for private repositories)
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
if [ -z "$GITHUB_TOKEN" ]; then
  echo "[entrypoint] ERROR: GITHUB_TOKEN is required for cloning private repositories." >&2
  echo "[entrypoint] Provide it at runtime: -e GITHUB_TOKEN=***" >&2
  exit 1
fi

clone_repo() {
  # $1=REPO (owner/name), $2=DIR
  REPO="$1"; DIR="$2"
  if [ -f "$DIR/package.json" ] || [ -d "$DIR/.git" ]; then
    echo "[entrypoint] Repo already present at $DIR; skipping clone"
    return 0
  fi
  echo "[entrypoint] Cloning $REPO (default branch) into $DIR"
  PARENT_DIR="$(dirname "$DIR")"
  mkdir -p "$PARENT_DIR"
  URL="https://github.com/${REPO}.git"
  AUTH_URL="https://${GITHUB_TOKEN}@github.com/${REPO}.git"
  # Use token in URL (your preferred style) and also forward auth to codeload
  if ! git \
    -c http.https://codeload.github.com/.extraheader="Authorization: Bearer $GITHUB_TOKEN" \
    clone --depth 1 "$AUTH_URL" "$DIR"; then
    echo "[entrypoint] ERROR: git clone failed for $REPO using token. Ensure the token has repo read access." >&2
    exit 1
  fi
  # Sanitize remote to avoid storing the token in .git/config
  git -C "$DIR" remote set-url origin "$URL"
}

# --- Clone Main App & Secondary ---
clone_repo "$APP_REPO" "$APP_DIR"
clone_repo "$SECONDARY_REPO" "$SECONDARY_DIR"

# --- Link shared into app path expected by source imports ---
APP_SHARED_LINK="$APP_DIR/shared"
if [ ! -e "$APP_SHARED_LINK" ]; then
  ln -s "$SECONDARY_DIR" "$APP_SHARED_LINK"
  echo "[entrypoint] Linked shared -> $APP_SHARED_LINK -> $SECONDARY_DIR"
fi

# --- Install app production deps (omit dev) ---
cd "$APP_DIR"
if [ ! -d node_modules ] || [ -z "$(ls -A node_modules 2>/dev/null)" ]; then
  echo "[entrypoint] Installing production dependencies in $APP_DIR ..."
  (npm ci --omit=dev || npm install --omit=dev)
fi

# --- Export env for app to find secondary directly ---
export SECONDARY_DIR="$SECONDARY_DIR"

# --- Copy theme.css into app public (so /assets/theme.css works) ---
THEME_SRC="$SECONDARY_DIR/theme.css"
THEME_DST_DIR="$APP_DIR/src/public/css"
THEME_DST="$THEME_DST_DIR/theme.css"
if [ -f "$THEME_SRC" ]; then
  mkdir -p "$THEME_DST_DIR"
  cp "$THEME_SRC" "$THEME_DST"
  echo "[entrypoint] Synced theme.css to $THEME_DST"
else
  echo "[entrypoint] WARNING: theme.css not found in $SECONDARY_DIR"
fi

exec "$@"
