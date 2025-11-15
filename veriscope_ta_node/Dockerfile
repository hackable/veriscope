FROM node:18-alpine

LABEL maintainer="Veriscope"

WORKDIR /app

# Install build dependencies for native modules
RUN apk add --no-cache python3 make g++

# Copy package files first for better caching
COPY ./veriscope_ta_node/package*.json ./

# Install dependencies
RUN npm install --production

# Copy application code (includes .env for runtime configuration)
COPY --chown=node:node ./veriscope_ta_node/ ./

# Create logs directory with correct permissions
RUN mkdir -p logs && chown -R node:node logs

# Switch to non-root user
USER node

EXPOSE 4000

CMD ["node", "http-api.js"]
