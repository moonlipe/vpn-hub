# syntax=docker/dockerfile:1.7

# =========================================================
# Stage 1 - build snx-rs a partir do source (Rust)
# =========================================================
# snx-rs usa Cargo edition2024, estabilizada só a partir do Rust 1.85 —
# 1.80 dava "feature `edition2024` is required". Usamos "rust:slim-bookworm"
# (sem pin de versão) pra sempre pegar o Rust estável mais recente e não
# repetir esse problema quando o snx-rs adotar features futuras.
FROM rust:slim-bookworm AS snx-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    pkg-config \
    libssl-dev \
    libsqlite3-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Fixado em v6.2.4 (a versão que compilou com sucesso) — evita que o
# build quebre de novo sem aviso quando o mantenedor fizer mudanças
# incompatíveis (como aconteceu com a exigência de edition2024). Pra
# atualizar deliberadamente no futuro, troque a tag aqui e teste o build
# antes de fazer merge/deploy.
ARG SNX_RS_VERSION=v6.2.4
RUN git clone --branch "${SNX_RS_VERSION}" --depth 1 https://github.com/ancwrd1/snx-rs.git .

RUN cargo build --release --bin snx-rs && \
    cargo build --release --bin snxctl

# =========================================================
# Stage 2 - build openfortivpn a partir do source (C/autotools)
# =========================================================
# O pacote `openfortivpn` do apt no Debian 12 (bookworm) é anterior à
# 1.23.0, quando o suporte a --saml-login foi adicionado — o daemon
# Python depende dessa flag, então precisamos compilar uma versão mais
# recente do source em vez de usar o pacote do apt.
FROM debian:bookworm-slim AS forti-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    automake \
    autoconf \
    libssl-dev \
    pkg-config \
    git \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Fixado numa tag específica (>=1.23.0, que tem --saml-login) pelo mesmo
# motivo do snx-rs: builds futuros não devem quebrar por mudanças
# incompatíveis no repositório upstream sem aviso.
ARG OPENFORTIVPN_VERSION=v1.23.1
RUN git clone --branch "${OPENFORTIVPN_VERSION}" --depth 1 \
    https://github.com/adrienverge/openfortivpn.git .

RUN ./autogen.sh && \
    ./configure --prefix=/usr --sysconfdir=/etc && \
    make -j"$(nproc)" && \
    # Confirma o binário compilado antes do COPY --from no stage final —
    # se o `make` mudar de layout de saída no futuro, isso falha aqui com
    # mensagem clara em vez de um "file not found" opaco no COPY.
    test -x /build/openfortivpn

# =========================================================
# Stage 3 - imagem final
# =========================================================
FROM debian:bookworm-slim

LABEL maintainer="infra@suaempresa.com"
LABEL description="Gateway VPN unificado: openfortivpn (daemon SAML/Playwright) + snx-rs + WireGuard"

ENV DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------
# Pacotes base + openfortivpn + wireguard + libs headless do Chromium
# (equivalente Debian/apt da lista dnf do setup.sh original, que era
# pra Oracle Linux/RHEL — os nomes de pacote mudam mas a cobertura é a
# mesma exigida pelo `playwright install-deps`)
# ------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    ppp \
    wireguard-tools \
    openresolv \
    iproute2 \
    iptables \
    iputils-ping \
    dnsutils \
    curl \
    ca-certificates \
    openssl \
    bash \
    procps \
    net-tools \
    sudo \
    gosu \
    python3 \
    python3-venv \
    python3-pip \
    libnss3 \
    libnspr4 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libcups2 \
    libdrm2 \
    libgbm1 \
    libxkbcommon0 \
    libxcomposite1 \
    libxdamage1 \
    libxfixes3 \
    libxrandr2 \
    libxshmfence1 \
    libpango-1.0-0 \
    libcairo2 \
    libasound2 \
    fonts-liberation \
    libsqlite3-0 \
    socat \
    && rm -rf /var/lib/apt/lists/*

# Binários do snx-rs e do openfortivpn (compilado do source, com SAML)
COPY --from=snx-builder /build/target/release/snx-rs /usr/local/bin/snx-rs
COPY --from=snx-builder /build/target/release/snxctl /usr/local/bin/snxctl
COPY --from=forti-builder /build/openfortivpn /usr/bin/openfortivpn
RUN chmod +x /usr/local/bin/snx-rs /usr/local/bin/snxctl /usr/bin/openfortivpn

# ------------------------------------------------------------
# Usuário não-root pro daemon, com sudo NOPASSWD restrito só ao
# openfortivpn e pkill (nada de rodar o container inteiro como root)
#
# O caminho do binário openfortivpn agora é fixo (/usr/bin/openfortivpn,
# definido no COPY --from=forti-builder acima), mas ainda resolvemos com
# `command -v` no momento do build por segurança — se o caminho de
# instalação mudar no futuro, o sudo recusaria silenciosamente (regra não
# bate com o caminho exato chamado) e travaria esperando senha.
# ------------------------------------------------------------
RUN useradd --system --create-home --home-dir /opt/vpn-daemon --shell /bin/bash vpndaemon && \
    OPENFORTIVPN_BIN="$(command -v openfortivpn)" && \
    PKILL_BIN="$(command -v pkill)" && \
    echo "vpndaemon ALL=(root) NOPASSWD: ${OPENFORTIVPN_BIN}, ${PKILL_BIN}" \
        > /etc/sudoers.d/vpndaemon && \
    chmod 440 /etc/sudoers.d/vpndaemon && \
    visudo -c && \
    echo "openfortivpn resolvido em: ${OPENFORTIVPN_BIN}" && \
    echo "pkill resolvido em: ${PKILL_BIN}"

# Estrutura de diretórios de config (serão montados como volumes em produção)
RUN mkdir -p \
    /etc/vpn-gateway/snx \
    /etc/vpn-gateway/wireguard \
    /var/log/vpn-gateway \
    /opt/vpn-daemon

# ------------------------------------------------------------
# Daemon Python (openfortivpn/SAML) — código já clonado no host
# via chave de deploy, copiado do build context em vpn-daemon/
# ------------------------------------------------------------

COPY vpn-daemon/ /opt/vpn-daemon/
COPY vpn-daemon/requirements.txt /opt/vpn-daemon/requirements.txt
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/vpn-daemon/.cache/ms-playwright
RUN python3 -m venv /opt/vpn-daemon/.venv && \
    /opt/vpn-daemon/.venv/bin/pip install --no-cache-dir --upgrade pip && \
    /opt/vpn-daemon/.venv/bin/pip install --no-cache-dir -r /opt/vpn-daemon/requirements.txt && \
    /opt/vpn-daemon/.venv/bin/python -m playwright install chromium chromium-headless-shell && \
    chown -R vpndaemon:vpndaemon /opt/vpn-daemon

RUN chown -R vpndaemon:vpndaemon /opt/vpn-daemon

# Scripts de controle (snx, wireguard, entrypoint, healthcheck)
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/start-snx.sh /usr/local/bin/start-snx.sh
COPY scripts/snx-watchdog.sh /usr/local/bin/snx-watchdog.sh
COPY scripts/start-wireguard.sh /usr/local/bin/start-wireguard.sh
COPY scripts/start-forti-daemon.sh /usr/local/bin/start-forti-daemon.sh
COPY scripts/healthcheck.sh /usr/local/bin/healthcheck.sh

RUN chmod +x \
    /usr/local/bin/entrypoint.sh \
    /usr/local/bin/start-snx.sh \
    /usr/local/bin/snx-watchdog.sh \
    /usr/local/bin/start-wireguard.sh \
    /usr/local/bin/start-forti-daemon.sh \
    /usr/local/bin/healthcheck.sh

# WireGuard precisa do módulo/dev tun; expõe a porta padrão caso o container
# também sirva de peer (ajuste conforme seu uso real)
EXPOSE 51820/udp

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]