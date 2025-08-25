# Generic Node runtime Dockerfile (runtime npm install + git fetch)
FROM node:lts-slim
WORKDIR /app

ENV NODE_ENV=production PORT=8080

# Minimal tools to fetch source at runtime
RUN apt-get update \
  && apt-get install -y --no-install-recommends git ca-certificates \
  && rm -rf /var/lib/apt/lists/*

# Copy shared entrypoint
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Healthcheck expects the app to expose /health on PORT
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "require('http').get('http://localhost:8080/health',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"

EXPOSE 8080
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["npm", "start"]
