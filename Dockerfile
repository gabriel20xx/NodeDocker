FROM node:latest

# Install git
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy startup script into the image
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Set default environment variable (can be overridden at runtime)
ENV GIT_REPO=https://github.com/username/repository.git

EXPOSE 3000

ENTRYPOINT ["/entrypoint.sh"]
