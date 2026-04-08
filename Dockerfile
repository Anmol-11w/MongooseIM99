# syntax=docker/dockerfile:1

FROM erlang:28-slim AS builder

WORKDIR /src

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash ca-certificates gcc g++ git libssl-dev make zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

COPY . .

RUN ./tools/configure system=yes prefix=/ \
    && make rel install \
    && test -f /etc/mongooseim/mongooseim.toml

FROM debian:trixie-slim AS runtime

# Install runtime dependencies
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash ca-certificates libncurses6 libstdc++6 openssl procps zlib1g \
    && rm -rf /var/lib/apt/lists/*

# Copy build artifacts
COPY --from=builder /etc/mongooseim /etc/mongooseim
COPY --from=builder /usr/bin/mongooseimctl /usr/bin/mongooseimctl
COPY --from=builder /usr/lib/mongooseim /usr/lib/mongooseim
COPY --from=builder /var/lib/mongooseim /var/lib/mongooseim
COPY --from=builder /var/log/mongooseim /var/log/mongooseim

# Ensure the config path exists and is writable for sed/awk
RUN touch /etc/mongooseim.toml && ln -sf /etc/mongooseim/mongooseim.toml /etc/mongooseim.toml

# Set environment variables
ENV EJABBERD_CONFIG_PATH=/etc/mongooseim.toml
WORKDIR /usr/lib/mongooseim

# --- SMOKE TEST GATEKEEPER ---
# We run this during the build. If it fails, the build fails.
COPY tools/wait-for-it.sh ./
COPY tools/pkg/scripts/smoke_test.sh ./
RUN chmod +x wait-for-it.sh smoke_test.sh && ./smoke_test.sh

# --- FINAL CONFIG ---
EXPOSE 5222 5269 5280 8888 9091

# We stay as ROOT user so your K8s 'sed -i' commands never hit permission issues
USER root

CMD ["/usr/lib/mongooseim/bin/mongooseim", "foreground"]