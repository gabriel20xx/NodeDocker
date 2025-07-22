FROM node:latest

# Install git
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

# Set environment variable (can be overridden at build or run time)
ARG GIT_REPO=https://github.com/username/repository.git
ENV GIT_REPO=${GIT_REPO}

# Define app folders
ENV APP_DIR=/app
ENV INPUT_DIR=/input
ENV OUTPUT_DIR=/output

# Clone repo and set up folders and permissions
RUN \
  echo "Cloning repo and preparing directories..." && \
  rm -rf ${APP_DIR} && \
  git clone ${GIT_REPO} ${APP_DIR} && \
  mkdir -p ${INPUT_DIR} ${OUTPUT_DIR} && \
  chown -R 99:100 ${APP_DIR} ${INPUT_DIR} ${OUTPUT_DIR} && \
  chmod -R 777 ${APP_DIR} ${INPUT_DIR} ${OUTPUT_DIR} && \
  cd ${APP_DIR} && \
  npm install

# Set working directory
WORKDIR ${APP_DIR}

# Expose the app port
EXPOSE 3000

# Use entrypoint from the cloned repo
ENTRYPOINT ["./entrypoint.sh"]
