# syntax=docker/dockerfile:1

# ---- Stage 1: install production dependencies ------------------------------
# Full Node image (with npm) is used only to build; it never ships.
# Base images are pinned by digest for reproducible builds (Dependabot proposes updates).
FROM node:24-trixie-slim@sha256:54f84b4cf8432b21aaffd5d3ce8d41e12cea0d10d33c09d2f3c9879d49d6b446 AS deps
WORKDIR /app
COPY package.json package-lock.json ./
# npm ci: exact versions from the lockfile; --omit=dev: no dev tooling in the image;
# --ignore-scripts: dependency install scripts can't run arbitrary code during the build
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund

# ---- Stage 2: runtime ------------------------------------------------------
# Distroless: only the Node runtime and its libraries – no shell, no package manager, no npm.
# Far fewer CVEs and nothing for an attacker to use if the app is compromised.
FROM gcr.io/distroless/nodejs24-debian13:nonroot@sha256:a6c34457f6da4295807e051411c7783739c65b997a324fed14e4fa292615ae91
WORKDIR /app
ENV NODE_ENV=production
# Only what the app needs at runtime, owned by root and read-only for the app user
COPY --from=deps /app/node_modules ./node_modules
COPY package.json app.js ./
# Explicit non-root user (uid 65532, provided by the :nonroot image)
USER nonroot
EXPOSE 8080
# Distroless entrypoint is the node binary; the app handles SIGTERM itself (see app.js)
CMD ["app.js"]
