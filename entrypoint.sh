#!/bin/bash
set -e

# Check GIT_REPO is set
if [ -z "$GIT_REPO" ]; then
  echo "Error: GIT_REPO environment variable is not set."
  exit 1
fi

# Completely clean and recreate /app
echo "Resetting /app..."
rm -rf /app
mkdir -p /app
chown -R 99:100 /app
chmod -R 777 /app

# Recreate /input and /output with correct ownership and permissions
echo "Creating /input and /output with uid:gid 99:100 and permissions 777..."
mkdir -p /input /output
chown -R 99:100 /input /output
chmod -R 777 /input /output

# Clone repo
echo "Cloning $GIT_REPO into /app..."
git clone "$GIT_REPO" /app

# Fix permissions again after clone (in case git resets them)
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
