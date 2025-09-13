#!/bin/sh
set -e

########################################
# Runtime Entry Configuration
# Supports transient network issues with retry for git clone & npm install.
# Environment overrides:
#   CLONE_MAX_ATTEMPTS         (default 4)
#   CLONE_BASE_BACKOFF_MS      (default 1500)
#   CLONE_JITTER_MS            (default 400)
#   CLONE_BACKOFF_MODE         (exponential|linear, default exponential)
#   INSTALL_MAX_ATTEMPTS       (default 3)
#   INSTALL_BASE_BACKOFF_MS    (default 2000)
#   INSTALL_BACKOFF_MODE       (exponential|linear, default inherits CLONE_BACKOFF_MODE)
#   INSTALL_JITTER_MS          (default 300)
#   JSON_LOG                   (1 enables JSON structured logs)
#   LOG_LEVEL                  (error|warn|info, default info; in JSON mode filters events)
#   APP_REF                    (branch, tag, or full/short commit to checkout after clone)
#   SKIP_REBUILD_BETTER_SQLITE (1 skip native rebuild – debugging only)
#   SKIP_INSTALL               (1 skip all npm install phases – debugging only)
# JSON logging line fields: ts, level, event, msg, plus contextual key=value pairs.
########################################
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

LOG_LEVEL_NORMALIZED=$(printf '%s' "${LOG_LEVEL:-info}" | tr 'A-Z' 'a-z')
json_should_log_level() {
  case "$LOG_LEVEL_NORMALIZED" in
    error) [ "$1" = "ERROR" ] && return 0 || return 1 ;;
    warn)  [ "$1" = "ERROR" ] || [ "$1" = "WARN" ] && return 0 || return 1 ;;
    info|*) return 0 ;;
  esac
}
json_log() {
  LEVEL="$1"; EVENT="$2"; shift 2; MSG="$1"; shift 1
  if [ "$JSON_LOG" = "1" ]; then
    UPPER_LEVEL=$(printf '%s' "$LEVEL" | tr 'a-z' 'A-Z')
    json_should_log_level "$UPPER_LEVEL" || return 0
    ESC_MSG=$(printf '%s' "$MSG" | sed 's/\\/\\\\/g; s/"/\\"/g')
    EXTRAS=""; for KV in "$@"; do
      K=$(printf '%s' "$KV" | awk -F= '{print $1}')
      V=$(printf '%s' "$KV" | awk -F= '{print $2}')
      V_ESC=$(printf '%s' "$V" | sed 's/\\/\\\\/g; s/"/\\"/g')
      if [ -n "$EXTRAS" ]; then EXTRAS="$EXTRAS, \"$K\": \"$V_ESC\""; else EXTRAS="\"$K\": \"$V_ESC\""; fi
    done
    TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if [ -n "$EXTRAS" ]; then
      printf '{"ts":"%s","level":"%s","event":"%s","msg":"%s",%s}\n' "$TS" "$UPPER_LEVEL" "$EVENT" "$ESC_MSG" "$EXTRAS"
    else
      printf '{"ts":"%s","level":"%s","event":"%s","msg":"%s"}\n' "$TS" "$UPPER_LEVEL" "$EVENT" "$ESC_MSG"
    fi
  else
    echo "[entrypoint] $LEVEL $EVENT - $MSG ${*:+($*)}" >&2
  fi
}

clone_repo() {
  # $1=REPO (owner/name), $2=DIR
  REPO="$1"; DIR="$2"
  if [ -f "$DIR/package.json" ] || [ -d "$DIR/.git" ]; then
    json_log INFO clone.skip "Repo already present" dir=$DIR repo=$REPO
    return 0
  fi
  PARENT_DIR="$(dirname "$DIR")"
  mkdir -p "$PARENT_DIR"
  URL="https://github.com/${REPO}.git"
  json_log INFO clone.start "Cloning repo" repo=$REPO dir=$DIR
  MAX_ATTEMPTS=${CLONE_MAX_ATTEMPTS:-4}
  BASE_BACKOFF=${CLONE_BASE_BACKOFF_MS:-1500}
  JITTER=${CLONE_JITTER_MS:-400}
  BACKOFF_MODE=${CLONE_BACKOFF_MODE:-exponential}
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
      json_log INFO clone.success "Clone succeeded" repo=$REPO dir=$DIR attempt=$ATTEMPT max=$MAX_ATTEMPTS durationSec=$DURATION
      rm -f /tmp/git_clone_err.$$ 2>/dev/null || true
        # If APP_REF is specified, attempt checkout (branch/tag/commit). For commits we deepen fetch to ensure object presence.
        if [ -n "$APP_REF" ]; then
          (cd "$DIR"; \
            if git rev-parse --verify "$APP_REF" >/dev/null 2>&1; then : ; else \
              git fetch --depth 5 origin "$APP_REF" || git fetch origin "$APP_REF" || true; fi; \
            if git checkout --quiet "$APP_REF" 2>/tmp/git_checkout_err.$$; then \
              REF_TYPE=$(git cat-file -t "$APP_REF" 2>/dev/null || echo unknown); \
              ACTIVE=$(git rev-parse --short HEAD 2>/dev/null || echo none); \
              json_log INFO clone.ref_checkout "Checked out ref" repo=$REPO ref=$APP_REF type=$REF_TYPE head=$ACTIVE; \
            else \
              ERR_CK=$(cat /tmp/git_checkout_err.$$ 2>/dev/null | tr '\n' ' '); \
              json_log WARN clone.ref_checkout_failed "Failed to checkout ref" repo=$REPO ref=$APP_REF error="$ERR_CK"; \
            fi )
        fi
      return 0
    fi
  ERR_MSG=$(cat /tmp/git_clone_err.$$ 2>/dev/null | tail -n 5 | tr '\n' ' ')
    json_log WARN clone.retry "Clone attempt failed" repo=$REPO dir=$DIR attempt=$ATTEMPT max=$MAX_ATTEMPTS error="${ERR_MSG}"
    if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
      json_log ERROR clone.exhausted "Exhausted clone attempts" repo=$REPO dir=$DIR attempt=$ATTEMPT max=$MAX_ATTEMPTS
      exit 1
    fi
    # Backoff with jitter
    if [ "$BACKOFF_MODE" = "linear" ]; then
      SLEEP_MS=$(( ATTEMPT * BASE_BACKOFF ))
    else
      SLEEP_MS=$(( ATTEMPT * ATTEMPT * BASE_BACKOFF ))
    fi
    if [ "$JITTER" -gt 0 ] 2>/dev/null; then
      RAND_JIT=$(( RANDOM % (JITTER + 1) ))
    else
      RAND_JIT=0
    fi
    TOTAL_MS=$(( SLEEP_MS + RAND_JIT ))
    SEC=$(awk "BEGIN {printf \"%.3f\", ${TOTAL_MS}/1000}")
    json_log INFO clone.backoff "Sleeping before retry" repo=$REPO dir=$DIR attempt=$ATTEMPT nextAttempt=$((ATTEMPT+1)) sleepSec=$SEC backoffMode=$BACKOFF_MODE
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

install_with_retry() {
  TARGET_DIR="$1"; LABEL="$2"
  MAX_ATTEMPTS=${INSTALL_MAX_ATTEMPTS:-3}
  BASE_BACKOFF=${INSTALL_BASE_BACKOFF_MS:-2000}
  JITTER=${INSTALL_JITTER_MS:-300}
  BACKOFF_MODE=${INSTALL_BACKOFF_MODE:-${CLONE_BACKOFF_MODE:-exponential}}
  ATTEMPT=1
  while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
    START_TS=$(date +%s)
    (cd "$TARGET_DIR"; if [ -f package-lock.json ]; then npm ci --omit=dev || npm install --omit=dev; else npm install --omit=dev; fi) && OK=1 || OK=0
    if [ $OK -eq 1 ]; then
      DURATION=$(( $(date +%s) - START_TS ))
      json_log INFO install.success "Install succeeded" dir=$TARGET_DIR label=$LABEL attempt=$ATTEMPT max=$MAX_ATTEMPTS durationSec=$DURATION backoffMode=$BACKOFF_MODE
      return 0
    fi
    if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
      json_log ERROR install.exhausted "Install failed after retries" dir=$TARGET_DIR label=$LABEL attempt=$ATTEMPT max=$MAX_ATTEMPTS
      return 1
    fi
    if [ "$BACKOFF_MODE" = "linear" ]; then
      SLEEP_MS=$(( ATTEMPT * BASE_BACKOFF ))
    else
      SLEEP_MS=$(( ATTEMPT * ATTEMPT * BASE_BACKOFF ))
    fi
    if [ "$JITTER" -gt 0 ] 2>/dev/null; then RAND_JIT=$(( RANDOM % (JITTER + 1) )); else RAND_JIT=0; fi
    TOTAL_MS=$(( SLEEP_MS + RAND_JIT ))
    SEC=$(awk "BEGIN {printf \"%.3f\", ${TOTAL_MS}/1000}")
    json_log WARN install.retry "Install attempt failed" dir=$TARGET_DIR label=$LABEL attempt=$ATTEMPT max=$MAX_ATTEMPTS sleepSec=$SEC backoffMode=$BACKOFF_MODE
    sleep "$SEC"
    ATTEMPT=$(( ATTEMPT + 1 ))
  done
}

if [ "${SKIP_INSTALL:-0}" = "1" ]; then
  json_log WARN install.skip "Skipping dependency installation due to SKIP_INSTALL=1"
else
  cd "$APP_DIR"
  if [ ! -d node_modules ] || [ -z "$(ls -A node_modules 2>/dev/null)" ]; then
    json_log INFO install.start "Installing production dependencies" dir=$APP_DIR label=app
    install_with_retry "$APP_DIR" app || json_log ERROR install.app_failed "App install ultimately failed" dir=$APP_DIR
  else
    json_log INFO install.detect "Existing node_modules detected (app)" dir=$APP_DIR
  fi
fi

# --- Install secondary (shared) production deps so its ESM imports resolve ---
if [ -f "$SECONDARY_DIR/package.json" ] && [ "${SKIP_INSTALL:-0}" != "1" ]; then
  if [ ! -d "$SECONDARY_DIR/node_modules" ] || [ -z "$(ls -A "$SECONDARY_DIR/node_modules" 2>/dev/null)" ]; then
    json_log INFO install.start "Installing shared production dependencies" dir=$SECONDARY_DIR label=shared
    install_with_retry "$SECONDARY_DIR" shared || json_log ERROR install.shared_failed "Shared install ultimately failed" dir=$SECONDARY_DIR
  else
    json_log INFO install.detect "Existing node_modules detected (shared)" dir=$SECONDARY_DIR
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
    json_log WARN install.missing_pkgs "Installing missing shared runtime packages" dir=$SECONDARY_DIR pkgs="$(echo $MISSING_PKGS | tr -s ' ')"
    if (cd "$SECONDARY_DIR"; npm install --no-audit --no-fund $MISSING_PKGS); then
      json_log INFO install.missing_done "Installed missing shared packages" dir=$SECONDARY_DIR
    else
      json_log WARN install.missing_retry "Missing package install failed – retrying once" dir=$SECONDARY_DIR
      sleep 2
      if (cd "$SECONDARY_DIR"; npm install --no-audit --no-fund $MISSING_PKGS); then
        json_log INFO install.missing_retry_success "Missing packages retry succeeded" dir=$SECONDARY_DIR
      else
        json_log ERROR install.missing_failed "Failed installing required shared packages" dir=$SECONDARY_DIR pkgs="$(echo $MISSING_PKGS | tr -s ' ')"
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
    json_log ERROR install.critical_missing "Critical shared packages missing after install" dir=$SECONDARY_DIR pkgs="$(echo $CRIT_MISSING | tr -s ' ')"
    json_log WARN install.critical_force "Attempting forced install of critical packages" dir=$SECONDARY_DIR
    (cd "$SECONDARY_DIR"; npm install --no-audit --no-fund $CRIT_MISSING || true)
  fi
fi

# --- Function: rebuild better-sqlite3 safely (handles host-mounted mismatches) ---
rebuild_better_sqlite3() {
  TARGET_DIR="$1"
  if [ -d "$TARGET_DIR/node_modules/better-sqlite3" ]; then
    json_log INFO sqlite.rebuild "Rebuilding better-sqlite3" dir=$TARGET_DIR
    (cd "$TARGET_DIR"; npm rebuild better-sqlite3 --build-from-source 2>&1 \
      || { json_log WARN sqlite.rebuild_failed "better-sqlite3 rebuild failed (continuing)" dir=$TARGET_DIR; return 0; })
  fi
}

# Always attempt a rebuild for both shared + app (covers pre-existing Windows / host binaries)
if [ "${SKIP_REBUILD_BETTER_SQLITE:-0}" != "1" ]; then
  rebuild_better_sqlite3 "$SECONDARY_DIR"
  rebuild_better_sqlite3 "$APP_DIR"
else
  json_log WARN sqlite.skip_rebuild "Skipping better-sqlite3 rebuild (SKIP_REBUILD_BETTER_SQLITE=1)"
fi

# Lightweight verification: check ELF magic if linux; log advisory if mismatch remains
verify_better_sqlite3() {
  TARGET_DIR="$1"
  NODE_BIN="$TARGET_DIR/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
  if [ -f "$NODE_BIN" ] && command -v head >/dev/null 2>&1; then
    MAGIC=$(head -c 4 "$NODE_BIN" | tr -d '\0')
    case "$MAGIC" in
      $'\x7fELF') : ;; # ok
      *) json_log WARN sqlite.binary_mismatch "Binary not ELF (possible host mismatch)" dir=$TARGET_DIR magic=$(printf '%q' "$MAGIC") ;;
    esac
  fi
}
verify_better_sqlite3 "$SECONDARY_DIR"
verify_better_sqlite3 "$APP_DIR"

# Final readiness event before handing off to CMD
json_log INFO runtime.ready "Entrypoint initialization complete" appDir=$APP_DIR sharedDir=$SECONDARY_DIR repo=$APP_REPO ref=${APP_REF:-default} driverHint=${DATABASE_URL:+postgres}

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
  json_log INFO theme.copy "Synced theme.css" src=$THEME_SRC dst=$THEME_DST
else
  json_log WARN theme.missing "theme.css not found" dir=$SECONDARY_DIR
fi

exec "$@"
