FROM node:latest

# Install git
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

# Do NOT use /app as the working dir yet — it will be created fresh later
WORKDIR /

# Copy the startup script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Default Git repo (can be overridden)
ENV GIT_REPO=https://github.com/username/repository.git

EXPOSE 3000

ENTRYPOINT ["/entrypoint.sh"]
