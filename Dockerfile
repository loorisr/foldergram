# syntax=docker/dockerfile:1.7

ARG NODE_IMAGE=node:22.23.4-bookworm-slim

# ---------------------------------------------------------------------------
# base: Node + pnpm (version pinned by the root package.json "packageManager")
# ---------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS base
ENV PNPM_HOME="/pnpm" \
    PNPM_STORE_DIR="/pnpm/store" \
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0
ENV PATH="$PNPM_HOME:$PATH"
WORKDIR /app
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN corepack enable && corepack install

# ---------------------------------------------------------------------------
# build: compile server (tsc) and client (vite). The output is plain JS/CSS,
# so this stage runs on the build host's native platform, avoiding slow QEMU
# emulation when producing the arm64 image.
# ---------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM base AS build
COPY client/package.json client/package.json
COPY server/package.json server/package.json
RUN --mount=type=cache,id=pnpm-store,target=/pnpm/store \
    pnpm install --frozen-lockfile --store-dir "$PNPM_STORE_DIR" \
      --filter @foldergram/server --filter @foldergram/client
COPY scripts scripts
COPY server server
COPY client client
RUN pnpm build

# ---------------------------------------------------------------------------
# prod-deps: server runtime dependencies only, installed for the target
# platform so native packages (sharp, dbmate) get the right binaries.
# ---------------------------------------------------------------------------
FROM base AS prod-deps
COPY server/package.json server/package.json
RUN --mount=type=cache,id=pnpm-store,target=/pnpm/store \
    pnpm install --prod --frozen-lockfile --store-dir "$PNPM_STORE_DIR" \
      --filter @foldergram/server

# ---------------------------------------------------------------------------
# runtime
# ---------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS runtime

RUN apt-get update \
  && apt-get install -y --no-install-recommends ffmpeg tini \
  && rm -rf /var/lib/apt/lists/*

ENV NODE_ENV=production \
    SERVER_PORT=4141

WORKDIR /app

# Layout mirrors the repository: the server resolves client/dist,
# server/db/migrations and data/ relative to the repository root (/app).
COPY package.json ./
COPY --from=prod-deps /app/node_modules ./node_modules
COPY --from=prod-deps /app/server/node_modules ./server/node_modules
COPY server/package.json server/package.json
COPY server/db server/db
COPY --from=build /app/server/dist server/dist
COPY --from=build /app/client/dist client/dist

EXPOSE 4141

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.SERVER_PORT||4141)+'/api/health').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))"

# tini reaps zombie ffmpeg processes and forwards SIGTERM so `docker stop`
# shuts the server down promptly instead of waiting for the kill timeout.
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["sh", "-c", "node server/dist/scripts/migrate.js && exec node server/dist/index.js"]
