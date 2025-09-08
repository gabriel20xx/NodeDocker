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

# GitHub token (optional; required for private repositories)
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

# --- Clean previous checkouts (fixed paths) ---
for TARGET in \
  "/app/NudeForge" \
  "/app/NudeFlow" \
  "/app/NudeShared" \
  "/app/NudeAdmin"
do
  if [ -e "$TARGET" ]; then
    echo "[entrypoint] Removing $TARGET"
    rm -rf "$TARGET"
  fi
done

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
  if [ -n "$GITHUB_TOKEN" ]; then
    AUTH_URL="https://${GITHUB_TOKEN}@github.com/${REPO}.git"
    if ! git clone --depth 1 "$AUTH_URL" "$DIR"; then
      echo "[entrypoint] ERROR: git clone failed for $REPO using token. Ensure the token has repo read access." >&2
      exit 1
    fi
    # Sanitize remote to avoid storing the token in .git/config
    git -C "$DIR" remote set-url origin "$URL"
  else
    if ! git clone --depth 1 "$URL" "$DIR"; then
      echo "[entrypoint] ERROR: git clone failed for $REPO. If the repo is private, pass -e GITHUB_TOKEN=***" >&2
      exit 1
    fi
  fi
}

# --- Clone Main App & Secondary ---
clone_repo "$APP_REPO" "$APP_DIR"
clone_repo "$SECONDARY_REPO" "$SECONDARY_DIR"

# --- Link shared into paths expected by source imports ---
# Many sources import '../../shared/...', which from /app/<App>/src resolves to /app/shared
GLOBAL_SHARED_LINK="/app/shared"
if [ ! -e "$GLOBAL_SHARED_LINK" ]; then
  ln -s "$SECONDARY_DIR" "$GLOBAL_SHARED_LINK"
  echo "[entrypoint] Linked shared -> $GLOBAL_SHARED_LINK -> $SECONDARY_DIR"
fi
# Keep app-local link too for any relative patterns expecting <app>/shared
APP_SHARED_LINK="$APP_DIR/shared"
if [ ! -e "$APP_SHARED_LINK" ]; then
  ln -s "$SECONDARY_DIR" "$APP_SHARED_LINK"
  echo "[entrypoint] Linked shared -> $APP_SHARED_LINK -> $SECONDARY_DIR"
fi

# --- Install app production deps (omit dev) ---
cd "$APP_DIR"
if [ ! -d node_modules ] || [ -z "$(ls -A node_modules 2>/dev/null)" ]; then
  echo "[entrypoint] Installing production dependencies in $APP_DIR ..."
  if [ -f package-lock.json ]; then
    npm ci --omit=dev || npm install --omit=dev
  else
    npm install --omit=dev
  fi
fi

# --- Install secondary (shared) production deps so its ESM imports resolve ---
if [ -f "$SECONDARY_DIR/package.json" ]; then
  if [ ! -d "$SECONDARY_DIR/node_modules" ] || [ -z "$(ls -A "$SECONDARY_DIR/node_modules" 2>/dev/null)" ]; then
    echo "[entrypoint] Installing production dependencies in $SECONDARY_DIR ..."
    (cd "$SECONDARY_DIR"; if [ -f package-lock.json ]; then npm ci --omit=dev || npm install --omit=dev; else npm install --omit=dev; fi)
  fi
  # Safety: ensure critical shared packages exist even if the remote repo still lists them under devDependencies
  REQUIRED_SECONDARY_PKGS="multer otplib qrcode archiver"
  MISSING_PKGS=""
  for P in $REQUIRED_SECONDARY_PKGS; do
    if [ ! -d "$SECONDARY_DIR/node_modules/$P" ]; then
      MISSING_PKGS="$MISSING_PKGS $P"
    fi
  done
  if [ -n "$(echo $MISSING_PKGS | tr -d ' ')" ]; then
    echo "[entrypoint] Detected missing shared runtime packages:$MISSING_PKGS -- installing (fallback)" >&2
    if (cd "$SECONDARY_DIR"; npm install --no-audit --no-fund $MISSING_PKGS); then
      echo "[entrypoint] Installed fallback shared packages successfully." >&2
    else
      echo "[entrypoint] WARNING: initial install of fallback packages failed; retrying once..." >&2
      sleep 2
      if (cd "$SECONDARY_DIR"; npm install --no-audit --no-fund $MISSING_PKGS); then
        echo "[entrypoint] Fallback retry succeeded." >&2
      else
        echo "[entrypoint] ERROR: Failed to install required shared packages ($MISSING_PKGS). Application start may fail." >&2
      fi
    fi
  fi
  # Final verification for critical packages (otplib, multer, archiver, qrcode)
  CRITICAL_PKGS="otplib multer archiver qrcode"
  CRIT_MISSING=""
  for P in $CRITICAL_PKGS; do
    [ -d "$SECONDARY_DIR/node_modules/$P" ] || CRIT_MISSING="$CRIT_MISSING $P"
  done
  if [ -n "$(echo $CRIT_MISSING | tr -d ' ')" ]; then
    echo "[entrypoint] ERROR: Critical shared packages still missing after install:$CRIT_MISSING" >&2
    echo "[entrypoint] Attempting forced install of critical packages..." >&2
    (cd "$SECONDARY_DIR"; npm install --no-audit --no-fund $CRIT_MISSING || true)
  fi
  # Rebuild native better-sqlite3 if present to avoid invalid ELF header when host-compiled modules leak in
  if [ -d "$SECONDARY_DIR/node_modules/better-sqlite3" ]; then
    echo "[entrypoint] Rebuilding better-sqlite3 native module for current container architecture..."
    (cd "$SECONDARY_DIR"; npm rebuild better-sqlite3 --build-from-source || echo "[entrypoint] WARNING: better-sqlite3 rebuild failed; will rely on Postgres if available")
  fi
fi

# --- Provide a top-level node_modules symlink for sibling resolution (optional) ---
if [ ! -e /app/node_modules ]; then
  ln -s "$APP_DIR/node_modules" /app/node_modules 2>/dev/null || true
fi

# --- Export env for app to find secondary directly ---
export SECONDARY_DIR="$SECONDARY_DIR"

# --- Copy theme.css into app public (so /assets/theme.css works) ---
# Prefer the real client theme file; fall back to root stub if needed
THEME_SRC="$SECONDARY_DIR/client/theme.css"
if [ ! -f "$THEME_SRC" ]; then
  THEME_SRC="$SECONDARY_DIR/theme.css"
fi
THEME_DST_DIR="$APP_DIR/src/public/css"
THEME_DST="$THEME_DST_DIR/theme.css"
if [ -f "$THEME_SRC" ]; then
  mkdir -p "$THEME_DST_DIR"
  cp "$THEME_SRC" "$THEME_DST"
  echo "[entrypoint] Synced theme.css from $THEME_SRC to $THEME_DST"
else
  echo "[entrypoint] WARNING: theme.css not found in $SECONDARY_DIR"
fi

exec "$@"
