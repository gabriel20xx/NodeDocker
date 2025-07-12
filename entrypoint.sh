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
mkdir /app
mkdir /input
mkdir /output

# Clone repo
echo "Cloning $GIT_REPO into /app..."
git clone "$GIT_REPO" /app

# Move into the app
cd /app

# Install dependencies
echo "Installing dependencies..."
npm install

# Run the app
echo "Starting the app..."
exec npm start
