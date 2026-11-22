# ---- build stage ----
FROM node:22-alpine AS deps
WORKDIR /app
COPY app/package*.json ./
RUN npm ci --omit=dev

# ---- runtime stage ----
FROM node:22-alpine
ENV NODE_ENV=production
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY app/server.js ./server.js
COPY app/package.json ./package.json
# run as the unprivileged "node" user that ships with the image
USER node
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://127.0.0.1:3000/health || exit 1
CMD ["node", "server.js"]
