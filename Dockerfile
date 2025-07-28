FROM node:lts-slim

# Install git
RUN apt-get update && apt-get upgrade -y && apt-get install -y git && rm -rf /var/lib/apt/lists/*

# Do NOT use /app as the working dir yet — it will be created fresh later
WORKDIR /

# Copy the startup script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV PORT=3000
EXPOSE $PORT

ENTRYPOINT ["/entrypoint.sh"]