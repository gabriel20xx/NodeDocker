FROM node:lts-slim

# Install git
RUN apt-get update && apt-get upgrade -y && apt-get install -y git && rm -rf /var/lib/apt/lists/*

# Do NOT use /app as the working dir yet — it will be created fresh later
WORKDIR /

# Copy the startup script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

###############################################
# Environment variables
# Required
# - PRIMARY_REPO: Git URL of the primary repo to clone (no default)
ENV PRIMARY_REPO=""

# Optional (Primary)
# - PRIMARY_BRANCH: Branch or tag to checkout for primary repo
# - PRIMARY_TOKEN:  Token for authenticated HTTPS clone of primary repo (set only at runtime; do NOT bake into image)
ENV PRIMARY_BRANCH=""

# Shared/Secondary (NudeShared or custom)
# - Set SECONDARY_SKIP=true to skip cloning the secondary repo
# - SECONDARY_REPO is required unless SECONDARY_SKIP=true
# - SECONDARY_BRANCH optional; SECONDARY_TOKEN for HTTPS auth (set only at runtime; do NOT bake into image)
ENV SECONDARY_SKIP="false"
ENV SECONDARY_REPO=""
ENV SECONDARY_BRANCH=""

# Standardized locations inside the container
# NUDESHARED_DIR is derived from SECONDARY_REPO (e.g., /app/<repo-name>/src) unless overridden at runtime
ENV INPUT_DIR="/input"
ENV OUTPUT_DIR="/output"
ENV UPLOAD_COPY_DIR="/copy"
ENV LORAS_DIR="/loras"

# App/runtime knobs
ENV FORCE_PROJECT_TYPE=""
ENV NPM_INSTALL_CMD="npm install"
ENV BUILD_CMD=""
ENV START_CMD="npm start"
ENV REBUILD_SHARP="true"
ENV SKIP_CAROUSEL_SETUP="false"
ENV NODE_ENV="production"

# App port
ENV PORT=8080
EXPOSE $PORT

ENTRYPOINT ["/entrypoint.sh"]