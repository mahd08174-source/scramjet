# syntax=docker/dockerfile:1

# ── Stage 1: Build the Rust/WASM rewriter ──────────────────────────────────
FROM rust:slim-bookworm AS wasm-builder

# Install system deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl bash ca-certificates build-essential pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Install Rust nightly + wasm target + rust-src
RUN rustup toolchain install nightly \
    && rustup target add wasm32-unknown-unknown --toolchain nightly \
    && rustup component add rust-src --toolchain nightly

# Install wasm-bindgen-cli (exact version required by build.sh)
RUN cargo install wasm-bindgen-cli --version 0.2.105 --locked

# Install binaryen (wasm-opt) and wasm-snip
RUN curl -L https://github.com/WebAssembly/binaryen/releases/download/version_119/binaryen-version_119-x86_64-linux.tar.gz \
    | tar xz --strip-components=1 -C /usr/local \
    && cargo install wasm-snip --locked

WORKDIR /app
COPY packages/core/rewriter ./packages/core/rewriter

# Build WASM with RELEASE=1
RUN cd packages/core/rewriter/wasm && RELEASE=1 bash build.sh

# ── Stage 2: Build JS bundles + demo ───────────────────────────────────────
FROM node:24-slim AS js-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install pnpm
RUN npm install -g pnpm@10.12.1

WORKDIR /app

# Copy the full repo
COPY . .

# Copy compiled WASM from stage 1
COPY --from=wasm-builder /app/packages/core/dist/scramjet.wasm ./packages/core/dist/scramjet.wasm

# Install deps
RUN pnpm install --frozen-lockfile

# Build all JS bundles (rspack: core, controller, utils, bootstrap)
RUN CI=1 pnpm exec rspack build --mode production

# Build the demo static site
RUN pnpm --filter @mercuryworkshop/scramjet-demo build

# ── Stage 3: Runtime ───────────────────────────────────────────────────────
FROM node:24-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
    git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g pnpm@10.12.1

WORKDIR /app

# Copy everything needed to run devserver.ts
COPY --from=js-builder /app/package.json ./package.json
COPY --from=js-builder /app/pnpm-lock.yaml ./pnpm-lock.yaml
COPY --from=js-builder /app/pnpm-workspace.yaml ./pnpm-workspace.yaml
COPY --from=js-builder /app/devserver.ts ./devserver.ts
COPY --from=js-builder /app/devlib.ts ./devlib.ts
COPY --from=js-builder /app/rspack.config.ts ./rspack.config.ts
COPY --from=js-builder /app/assets ./assets
COPY --from=js-builder /app/node_modules ./node_modules
COPY --from=js-builder /app/packages ./packages

ENV PORT=3000
ENV DEMO_PORT=3000
ENV WISP_PORT=4142

EXPOSE 3000

CMD ["node", "--no-warnings=ExperimentalWarning", "devserver.ts"]
