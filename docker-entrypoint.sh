#!/bin/sh
set -e

# Application repo & ref (override via env)
APP_REPO="${APP_REPO:-gabriel20xx/NudeFlow}"
APP_REF="${APP_REF:-master}"
APP_DIR="${APP_DIR:-/app}"

# Clone repo if package.json not present
if [ ! -f "$APP_DIR/package.json" ]; then
  echo "[entrypoint] Cloning application source: $APP_REPO@$APP_REF"
  git init "$APP_DIR"
  cd "$APP_DIR"
  # Always use a clean remote URL (no token in URL to avoid leaking in logs)
  git remote add origin "https://github.com/${APP_REPO}.git"
  # Fetch with optional Authorization header when token is provided
  if [ -n "$GITHUB_TOKEN" ]; then
    if ! git -c http.extraheader="Authorization: Bearer $GITHUB_TOKEN" fetch --depth 1 origin "$APP_REF"; then
      # Fallback: try 'main' if default 'master' not found
      if [ "$APP_REF" = "master" ]; then
        echo "[entrypoint] fetch failed for 'master'; trying 'main'..." >&2
        if git -c http.extraheader="Authorization: Bearer $GITHUB_TOKEN" fetch --depth 1 origin main; then
          APP_REF=main
        else
          echo "[entrypoint] git fetch failed; check APP_REPO/APP_REF or token" >&2
          exit 1
        fi
      else
        echo "[entrypoint] git fetch failed; check APP_REPO/APP_REF or token" >&2
        exit 1
      fi
    fi
  else
    if ! git fetch --depth 1 origin "$APP_REF"; then
      if [ "$APP_REF" = "master" ]; then
        echo "[entrypoint] fetch failed for 'master'; trying 'main'..." >&2
        if git fetch --depth 1 origin main; then
          APP_REF=main
        else
          echo "[entrypoint] git fetch failed; check APP_REPO/APP_REF" >&2
          exit 1
        fi
      else
        echo "[entrypoint] git fetch failed; check APP_REPO/APP_REF" >&2
        exit 1
      fi
    fi
  fi
  git checkout -B runtime-fetch FETCH_HEAD
else
  echo "[entrypoint] Existing source detected; skipping clone"
  cd "$APP_DIR"
fi

# Configure GitHub Packages auth if provided
if [ -n "$NPM_TOKEN" ]; then
  npm config set @gabriel20xx:registry https://npm.pkg.github.com
  npm config set //npm.pkg.github.com/:_authToken "$NPM_TOKEN"
fi

# Install production deps if node_modules is missing or empty
if [ ! -d node_modules ] || [ -z "$(ls -A node_modules 2>/dev/null)" ]; then
  echo "[entrypoint] Installing production dependencies..."
  (npm ci --omit=dev || npm install --omit=dev)
fi

# No need to copy theme.css; apps will serve it directly from the npm package

exec "$@"
