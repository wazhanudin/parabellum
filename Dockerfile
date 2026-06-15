# Stage 1: Asset Preparation (Bun)
FROM oven/bun:1.2.20 AS bun-builder
WORKDIR /app
COPY . .
RUN bun install --frozen-lockfile
RUN bun run build:release

# Stage 2: Rust Compilation
FROM rust:1.95-slim-trixie AS rust-builder
WORKDIR /app

# Install native dependencies required for building dependencies
RUN apt-get update && apt-get install -y --no-install-recommends pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*

# Pull Bun compiled assets from previous stage
COPY --from=bun-builder /app .

ENV SQLX_OFFLINE=true
RUN cargo build --release \
    --bin parabellum \
    --bin parabellum-seed

# Install sqlx-cli inside the builder stage to extract the binary for migrations
RUN cargo install sqlx-cli --no-default-features --features postgres

# Stage 3: High-Performance Production Runtime Environment
FROM bitnami/minideb:trixie
WORKDIR /app

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Configure isolated application execution account (UID 10001)
RUN useradd -m -u 10001 parabellum
RUN mkdir -p /app/logs /app/mnt /app/migrations

# Pull pre-compiled binaries and assets from builder stage
COPY --from=rust-builder /usr/local/cargo/bin/sqlx /app/bin/sqlx
COPY --from=rust-builder /app/target/release/parabellum /app/bin/parabellum
COPY --from=rust-builder /app/target/release/parabellum-seed /app/bin/parabellum-seed
COPY --from=rust-builder /app/seed /app/seed/
COPY --from=rust-builder /app/migrations /app/migrations/
COPY --from=rust-builder /app/frontend /app/frontend/

# Setup runtime initialization script
RUN echo '#!/bin/sh\n\
echo "Executing SQLx DB Migrations..."\n\
/app/bin/sqlx migrate run --database-url "$DATABASE_URL" --source /app/migrations\n\
echo "Seeding default game map data..."\n\
/app/bin/parabellum-seed || echo "Seeding skipped or already initialized."\n\
echo "Launching Parabellum Engine Core..."\n\
exec /app/bin/parabellum' > /app/entrypoint.sh && chmod +x /app/entrypoint.sh

RUN chown -R parabellum:parabellum /app
USER parabellum

ENV PORT=8080
EXPOSE 8080

CMD ["/app/entrypoint.sh"]