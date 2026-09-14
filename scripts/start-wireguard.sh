#!/bin/bash
set -euo pipefail

# Uso: start-wireguard.sh <caminho_do_config.conf>
# Cada instância gerencia UMA interface WireGuard.

WG_CONFIG="${1:?Uso: $0 <caminho_do_config.conf>}"
WG_IFACE="$(basename "$WG_CONFIG" .conf)"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [wireguard/$WG_IFACE] $*"
}

if [ ! -f "$WG_CONFIG" ]; then
    log "Config não encontrada em $WG_CONFIG"
    exit 1
fi

log "Subindo interface $WG_IFACE"

# wg-quick precisa que o arquivo esteja em /etc/wireguard/<iface>.conf
mkdir -p /etc/wireguard
cp "$WG_CONFIG" "/etc/wireguard/${WG_IFACE}.conf"
chmod 600 "/etc/wireguard/${WG_IFACE}.conf"

wg-quick up "$WG_IFACE"

log "Interface $WG_IFACE ativa. Mantendo processo vivo para monitoramento..."

# wg-quick up sobe e retorna, não fica em foreground.
# Mantemos o script vivo monitorando a interface, e derrubamos limpo no TERM.
trap 'log "Derrubando $WG_IFACE..."; wg-quick down "$WG_IFACE"; exit 0' SIGTERM SIGINT

while true; do
    if ! ip link show "$WG_IFACE" &>/dev/null; then
        log "Interface $WG_IFACE caiu inesperadamente!"
        exit 1
    fi
    sleep 15
done
