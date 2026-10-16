# syntax=docker/dockerfile:1

# ---- Build stage: Node toolchain, discarded after build ----
FROM node:24-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci --no-audit --no-fund
COPY public ./public
COPY src ./src
# Same-origin API path: nginx proxies /api to the backend, so the image is environment-agnostic
ARG REACT_APP_API_BASE_URL=/api
ENV REACT_APP_API_BASE_URL=$REACT_APP_API_BASE_URL GENERATE_SOURCEMAP=false
RUN npm run build

# ---- Runtime stage: static files on unprivileged nginx (uid 101, port 8080) ----
FROM nginxinc/nginx-unprivileged:1.27-alpine
# Rendered by the nginx entrypoint with envsubst (BACKEND_URL) into /etc/nginx/conf.d/default.conf
COPY nginx.conf.template /etc/nginx/templates/default.conf.template
COPY --from=build /app/build /usr/share/nginx/html
# NGINX_ENTRYPOINT_LOCAL_RESOLVERS makes the entrypoint export NGINX_LOCAL_RESOLVERS (Docker's DNS)
ENV BACKEND_URL=http://backend:8080 NGINX_ENTRYPOINT_LOCAL_RESOLVERS=1
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=3s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1
