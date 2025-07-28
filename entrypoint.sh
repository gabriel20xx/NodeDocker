#!/bin/bash
set -e

# Check GIT_REPO is set
if [ -z "$GIT_REPO" ]; then
  echo "Error: GIT_REPO environment variable is not set."
  exit 1
fi

# Detect protocol
if [[ "$GIT_REPO" == git@* ]]; then
  CLONE_METHOD="ssh"
elif [[ "$GIT_REPO" == https://* ]]; then
  CLONE_METHOD="https"
else
  echo "Error: GIT_REPO must start with https:// or git@"
  exit 1
fi

# If using HTTPS and a GIT_TOKEN is set, inject token into the URL
if [ "$CLONE_METHOD" = "https" ] && [ -n "$GIT_TOKEN" ]; then
  # Inject token into the HTTPS URL (e.g., https://<token>@github.com/user/repo.git)
  AUTH_REPO=$(echo "$GIT_REPO" | sed -E "s#https://#https://$GIT_TOKEN@#")
else
  AUTH_REPO="$GIT_REPO"
fi

# Clean and recreate /app
echo "Resetting /app..."
rm -rf /app
mkdir -p /app
chown -R 99:100 /app
chmod -R 777 /app

# Clone the repo (with optional branch)
if [ -n "$GIT_BRANCH" ]; then
  echo "Cloning branch '$GIT_BRANCH' from $GIT_REPO into /app..."
  git clone --branch "$GIT_BRANCH" "$AUTH_REPO" /app
else
  echo "Cloning default branch from $GIT_REPO into /app..."
  git clone "$AUTH_REPO" /app
fi

# Fix permissions
chown -R 99:100 /app
chmod -R 777 /app

# Move into the app
cd /app

# Install dependencies
echo "Installing dependencies..."
npm install

# Run the app
echo "Starting the app..."
exec npm start
