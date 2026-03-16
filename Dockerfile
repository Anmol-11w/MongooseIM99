# syntax=docker/dockerfile:1

FROM erlang:28-slim AS builder

WORKDIR /src

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        gcc \
        g++ \
        git \
        libssl-dev \
        make \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

COPY . .

RUN ./tools/configure system=yes prefix=/ \
    && make rel install


FROM debian:trixie-slim AS runtime

ENV MONGOOSEIM_HOME=/usr/lib/mongooseim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        libncurses6 \
        libstdc++6 \
        openssl \
        procps \
        zlib1g \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system mongooseim \
    && useradd --system --gid mongooseim --home-dir /var/lib/mongooseim --shell /usr/sbin/nologin mongooseim

COPY --from=builder /etc/mongooseim /etc/mongooseim
COPY --from=builder /usr/bin/mongooseimctl /usr/bin/mongooseimctl
COPY --from=builder /usr/lib/mongooseim /usr/lib/mongooseim
COPY --from=builder /var/lib/mongooseim /var/lib/mongooseim
COPY --from=builder /var/log/mongooseim /var/log/mongooseim
COPY --from=builder /var/lock/mongooseim /var/lock/mongooseim

RUN chown -R mongooseim:mongooseim /var/lib/mongooseim /var/log/mongooseim /var/lock/mongooseim

WORKDIR /usr/lib/mongooseim

EXPOSE 5222 5269 5280 5285 5541 5551 5561 8088 8089 8888 9091

VOLUME ["/var/lib/mongooseim", "/var/log/mongooseim"]

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=5 \
  CMD ["/usr/lib/mongooseim/bin/mongooseim", "ping"]

USER mongooseim

CMD ["/usr/lib/mongooseim/bin/mongooseim", "foreground"]