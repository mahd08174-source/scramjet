# syntax=docker/dockerfile:1

# ── Stage 1: Build the Rust/WASM rewriter ──────────────────────────────────
FROM rust:slim-bookworm AS wasm-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl bash ca-certificates build-essential pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Install Rust nightly + wasm target + rust-src
RUN rustup toolchain install nightly \
    && rustup target add wasm32-unknown-unknown --toolchain nightly \
    && rustup component add rust-src --toolchain nightly

# Install wasm-bindgen-cli (exact version required)
RUN cargo install wasm-bindgen-cli --version 0.2.105 --locked

# Install binaryen (wasm-opt)
RUN curl -L https://github.com/WebAssembly/binaryen/releases/download/version_119/binaryen-version_119-x86_64-linux.tar.gz \
    | tar xz --strip-components=1 -C /usr/local

WORKDIR /app
COPY packages/core/rewriter ./packages/core/rewriter

# Build WASM with absolute paths throughout
RUN set -eux; \
    export RUSTFLAGS='-Zlocation-detail=none -Zfmt-debug=none'; \
    cargo +nightly build --release \
        --manifest-path /app/packages/core/rewriter/Cargo.toml \
        --target wasm32-unknown-unknown \
        -Z build-std=panic_abort,std \
        -Z build-std-features=optimize_for_size \
        --no-default-features; \
    mkdir -p /app/packages/core/rewriter/wasm/out; \
    wasm-bindgen \
        --target web \
        --out-dir /app/packages/core/rewriter/wasm/out/ \
        /app/packages/core/rewriter/target/wasm32-unknown-unknown/release/wasm.wasm; \
    sed -i 's/import.meta.url/""/g' /app/packages/core/rewriter/wasm/out/wasm.js; \
    mkdir -p /app/packages/core/dist/; \
    wasm-opt /app/packages/core/rewriter/wasm/out/wasm_bg.wasm \
        -o /app/packages/core/dist/scramjet.wasm \
        --converge -tnh --vacuum -O4 -Oz \
    || cp /app/packages/core/rewriter/wasm/out/wasm_bg.wasm \
          /app/packages/core/dist/scramjet.wasm

# ── Stage 2: Build JS bundles + demo ───────────────────────────────────────
FROM node:24-slim AS js-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g pnpm@10.12.1

WORKDIR /app
COPY . .

# Copy compiled WASM from stage 1
COPY --from=wasm-builder /app/packages/core/dist/scramjet.wasm ./packages/core/dist/scramjet.wasm

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
