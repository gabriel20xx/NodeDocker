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

# Clone repo
if [ -n "$GIT_BRANCH" ]; then
  echo "Cloning branch $GIT_BRANCH from $GIT_REPO into /app..."
  git clone --branch "$GIT_BRANCH" "$GIT_REPO" /app
else
  echo "Cloning default branch from $GIT_REPO into /app..."
  git clone "$GIT_REPO" /app
fi

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
