#!/bin/sh
set -e

# --- Config (fixed directories) ---
# Main app to run (e.g. gabriel20xx/NudeForge or gabriel20xx/NudeFlow)
APP_REPO="${APP_REPO:-gabriel20xx/NudeForge}"
APP_REF="${APP_REF:-master}"

# Map repo -> fixed directory
APP_BASENAME="$(echo "$APP_REPO" | awk -F/ '{print $NF}')"
case "$APP_BASENAME" in
  NudeForge)
    APP_DIR="/app/NudeForge"
    ;;
  NudeFlow)
    APP_DIR="/app/NudeFlow"
    ;;
  *)
    echo "[entrypoint] Unsupported APP_REPO '$APP_REPO'. Set APP_REPO to 'gabriel20xx/NudeForge' or 'gabriel20xx/NudeFlow'." >&2
    exit 1
    ;;
esac

# Shared repo (NudeShared) at fixed path
NUDESHARED_REPO="${NUDESHARED_REPO:-gabriel20xx/NudeShared}"
NUDESHARED_REF="${NUDESHARED_REF:-main}"
NUDESHARED_DIR="/app/NudeShared"

# NPM GitHub Packages token (optional)
NPM_TOKEN="${NPM_TOKEN:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

clone_repo() {
  # $1=REPO (owner/name), $2=REF, $3=DIR
  REPO="$1"; REF="$2"; DIR="$3"
  if [ -f "$DIR/package.json" ] || [ -d "$DIR/.git" ]; then
    echo "[entrypoint] Repo already present at $DIR; skipping clone"
    return 0
  fi
  echo "[entrypoint] Cloning $REPO@$REF into $DIR"
  mkdir -p "$DIR"
  git init "$DIR"
  cd "$DIR"
  git remote add origin "https://github.com/${REPO}.git"
  if [ -n "$GITHUB_TOKEN" ]; then
    if ! git -c http.extraheader="Authorization: Bearer $GITHUB_TOKEN" fetch --depth 1 origin "$REF"; then
      if [ "$REF" = "master" ]; then
        echo "[entrypoint] fetch failed for 'master'; trying 'main'..." >&2
        if git -c http.extraheader="Authorization: Bearer $GITHUB_TOKEN" fetch --depth 1 origin main; then
          REF=main
        else
          echo "[entrypoint] git fetch failed; check $REPO/$REF or token" >&2
          exit 1
        fi
      else
        echo "[entrypoint] git fetch failed; check $REPO/$REF or token" >&2
        exit 1
      fi
    fi
  else
    if ! git fetch --depth 1 origin "$REF"; then
      if [ "$REF" = "master" ]; then
        echo "[entrypoint] fetch failed for 'master'; trying 'main'..." >&2
        if git fetch --depth 1 origin main; then
          REF=main
        else
          echo "[entrypoint] git fetch failed; check $REPO/$REF" >&2
          exit 1
        fi
      else
        echo "[entrypoint] git fetch failed; check $REPO/$REF" >&2
        exit 1
      fi
    fi
  fi
  git checkout -B runtime-fetch FETCH_HEAD
}

# --- Clone Main App & Shared ---
clone_repo "$APP_REPO" "$APP_REF" "$APP_DIR"
clone_repo "$NUDESHARED_REPO" "$NUDESHARED_REF" "$NUDESHARED_DIR"

# --- Link shared into app path expected by source imports ---
APP_SHARED_LINK="$APP_DIR/shared"
if [ ! -e "$APP_SHARED_LINK" ]; then
  ln -s "$NUDESHARED_DIR" "$APP_SHARED_LINK"
  echo "[entrypoint] Linked shared -> $APP_SHARED_LINK -> $NUDESHARED_DIR"
fi

# --- Configure NPM GitHub Packages auth if provided ---
if [ -n "$NPM_TOKEN" ]; then
  npm config set @gabriel20xx:registry https://npm.pkg.github.com
  npm config set //npm.pkg.github.com/:_authToken "$NPM_TOKEN"
fi

# --- Install app production deps (omit dev) ---
cd "$APP_DIR"
if [ ! -d node_modules ] || [ -z "$(ls -A node_modules 2>/dev/null)" ]; then
  echo "[entrypoint] Installing production dependencies in $APP_DIR ..."
  (npm ci --omit=dev || npm install --omit=dev)
fi

# --- Export env for app to find shared directly ---
export NUDESHARED_DIR="/app/NudeShared"

# --- Copy theme.css into app public (so /assets/theme.css works) ---
THEME_SRC="/app/NudeShared/theme.css"
THEME_DST_DIR="$APP_DIR/src/public/css"
THEME_DST="$THEME_DST_DIR/theme.css"
if [ -f "$THEME_SRC" ]; then
  mkdir -p "$THEME_DST_DIR"
  cp "$THEME_SRC" "$THEME_DST"
  echo "[entrypoint] Synced theme.css to $THEME_DST"
else
  echo "[entrypoint] WARNING: theme.css not found in $NUDESHARED_DIR"
fi

exec "$@"
