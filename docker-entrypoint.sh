#!/bin/sh
set -e

# --- Config (minimal) ---
# Supports transient network issues with retry for git clone.
# Environment overrides:
#   CLONE_MAX_ATTEMPTS (default 4)
#   CLONE_BASE_BACKOFF_MS (default 1500) – exponential backoff multiplier (attempt^2)
#   CLONE_JITTER_MS (default 400) – random additional sleep up to this many ms
#   SKIP_REBUILD_BETTER_SQLITE=1 – (optional) skip native rebuild (for debugging only)
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
  PARENT_DIR="$(dirname "$DIR")"
  mkdir -p "$PARENT_DIR"
  URL="https://github.com/${REPO}.git"
  echo "[entrypoint] Cloning $REPO (default branch) into $DIR (with retry)"
  MAX_ATTEMPTS=${CLONE_MAX_ATTEMPTS:-4}
  BASE_BACKOFF=${CLONE_BASE_BACKOFF_MS:-1500}
  JITTER=${CLONE_JITTER_MS:-400}
  ATTEMPT=1
  while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
    START_TS=$(date +%s)
    if [ -n "$GITHUB_TOKEN" ]; then
      AUTH_URL="https://${GITHUB_TOKEN}@github.com/${REPO}.git"
      git clone --depth 1 "$AUTH_URL" "$DIR" 2>/tmp/git_clone_err.$$ && CLONE_OK=1 || CLONE_OK=0
      # Sanitize remote if success
      if [ $CLONE_OK -eq 1 ]; then
        git -C "$DIR" remote set-url origin "$URL" || true
      fi
    else
      git clone --depth 1 "$URL" "$DIR" 2>/tmp/git_clone_err.$$ && CLONE_OK=1 || CLONE_OK=0
    fi
    if [ $CLONE_OK -eq 1 ]; then
      DURATION=$(( $(date +%s) - START_TS ))
      echo "[entrypoint] Clone succeeded for $REPO in ${DURATION}s on attempt $ATTEMPT"
      rm -f /tmp/git_clone_err.$$ 2>/dev/null || true
      return 0
    fi
    ERR_MSG=$(cat /tmp/git_clone_err.$$ 2>/dev/null | tail -n 5)
    echo "[entrypoint] WARN: clone attempt $ATTEMPT/$MAX_ATTEMPTS failed for $REPO: ${ERR_MSG}" >&2
    if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
      echo "[entrypoint] ERROR: Exhausted clone attempts for $REPO. Giving up." >&2
      exit 1
    fi
    # Exponential backoff with jitter (attempt^2 * base + random[0,JITTER])
    SLEEP_MS=$(( ATTEMPT * ATTEMPT * BASE_BACKOFF ))
    if [ "$JITTER" -gt 0 ] 2>/dev/null; then
      RAND_JIT=$(( RANDOM % (JITTER + 1) ))
    else
      RAND_JIT=0
    fi
    TOTAL_MS=$(( SLEEP_MS + RAND_JIT ))
    SEC=$(awk "BEGIN {printf \"%.3f\", ${TOTAL_MS}/1000}")
    echo "[entrypoint] Retry in ${SEC}s (attempt $(($ATTEMPT+1)) of $MAX_ATTEMPTS)" >&2
    sleep "$SEC"
    ATTEMPT=$(( ATTEMPT + 1 ))
  done
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
fi

# --- Function: rebuild better-sqlite3 safely (handles host-mounted mismatches) ---
rebuild_better_sqlite3() {
  TARGET_DIR="$1"
  if [ -d "$TARGET_DIR/node_modules/better-sqlite3" ]; then
    echo "[entrypoint] (better-sqlite3) Ensuring native binary matches container in $TARGET_DIR" >&2
    (cd "$TARGET_DIR"; npm rebuild better-sqlite3 --build-from-source 2>&1 \
      || { echo "[entrypoint] WARNING: native rebuild failed in $TARGET_DIR (continuing)" >&2; return 0; })
  fi
}

# Always attempt a rebuild for both shared + app (covers pre-existing Windows / host binaries)
if [ "${SKIP_REBUILD_BETTER_SQLITE:-0}" != "1" ]; then
  rebuild_better_sqlite3 "$SECONDARY_DIR"
  rebuild_better_sqlite3 "$APP_DIR"
else
  echo "[entrypoint] Skipping better-sqlite3 rebuild due to SKIP_REBUILD_BETTER_SQLITE=1" >&2
fi

# Lightweight verification: check ELF magic if linux; log advisory if mismatch remains
verify_better_sqlite3() {
  TARGET_DIR="$1"
  NODE_BIN="$TARGET_DIR/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
  if [ -f "$NODE_BIN" ] && command -v head >/dev/null 2>&1; then
    MAGIC=$(head -c 4 "$NODE_BIN" | tr -d '\0')
    case "$MAGIC" in
      $'\x7fELF') : ;; # ok
      *) echo "[entrypoint] WARNING: better_sqlite3.node in $TARGET_DIR does not appear to be an ELF binary (magic: $(printf '%q' "$MAGIC")); signup requiring SQLite may fail. Consider removing host node_modules before starting container." >&2 ;;
    esac
  fi
}
verify_better_sqlite3 "$SECONDARY_DIR"
verify_better_sqlite3 "$APP_DIR"

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
