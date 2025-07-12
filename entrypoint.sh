#!/bin/bash
set -e

# Check if GIT_REPO env var is set
if [ -z "$GIT_REPO" ]; then
  echo "Error: GIT_REPO environment variable is not set."
  exit 1
fi

# Fully clean the /app directory
echo "Cleaning /app directory..."
rm -rf /app
mkdir /app

# Clone the repo into /app
echo "Cloning repository $GIT_REPO..."
git clone "$GIT_REPO" /app

echo "Contents of /app after clone:"
ls -la /app

# Change directory to /app
cd /app

# Install dependencies
echo "Installing npm dependencies..."
npm install

# Run the app
echo "Starting the app..."
exec npm start