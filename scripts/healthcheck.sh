#!/bin/bash
# Retorna 0 (saudável) se pelo menos uma VPN configurada está com interface ativa.
# Retorna 1 se nenhuma interface esperada está de pé.

FOUND_ANY_CONFIG=0
FOUND_ANY_UP=0

if [ -n "${VPN_GATEWAY:-}" ] && [ -n "${VPN_USERNAME:-}" ] && [ -n "${VPN_PASSWORD:-}" ]; then
    FOUND_ANY_CONFIG=1
    if ip link show ppp0 &>/dev/null; then
        FOUND_ANY_UP=1
    fi
fi

if [ -f /etc/vpn-hub/snx/config.toml ]; then
    FOUND_ANY_CONFIG=1
    # snx-rs geralmente cria tun0/snx0 — ajuste o nome conforme a versão usada
    if ip link show tun0 &>/dev/null || ip link show snx0 &>/dev/null; then
        FOUND_ANY_UP=1
    fi
fi

if [ -f /etc/vpn-hub/wireguard/wg0.conf ]; then
    FOUND_ANY_CONFIG=1
    if ip link show wg0 &>/dev/null; then
        FOUND_ANY_UP=1
    fi
fi

if [ "$FOUND_ANY_CONFIG" -eq 0 ]; then
    # Nenhuma VPN configurada não é necessariamente "doente" -- ajuste se
    # quiser que isso falhe o healthcheck.
    exit 0
fi

if [ "$FOUND_ANY_UP" -eq 1 ]; then
    exit 0
else
    exit 1
fi
