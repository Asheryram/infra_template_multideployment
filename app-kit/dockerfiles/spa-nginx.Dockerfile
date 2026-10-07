# Static SPA (React / Vue / Angular / Svelte / Vite) served by nginx, with RUNTIME config.
# One image works in every environment: API_URL etc. are written to /env.js when the
# container starts, so previews can point at different backends without rebuilding.
#
# Copy this file to your repo root as "Dockerfile" and the spa/ folder to ./deploy-spa/
# In index.html, BEFORE your bundle:   <script src="/env.js"></script>
# In code:                             const api = window.__ENV__.API_URL
FROM node:22-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
ARG BUILD_DIR=dist
RUN npm run build && mv "$BUILD_DIR" /out

FROM nginx:1.27-alpine
COPY deploy-spa/nginx.conf /etc/nginx/conf.d/default.conf
COPY deploy-spa/40-runtime-env.sh /docker-entrypoint.d/40-runtime-env.sh
RUN chmod +x /docker-entrypoint.d/40-runtime-env.sh
COPY --from=build /out /usr/share/nginx/html
EXPOSE 80
HEALTHCHECK --interval=15s --timeout=3s --retries=3 CMD wget -qO- http://127.0.0.1/healthz >/dev/null || exit 1
