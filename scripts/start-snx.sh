#!/bin/bash
set -euo pipefail

CONFIG_FILE="/etc/vpn-hub/snx/config.toml"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [snx] $*"
}

if [ ! -f "$CONFIG_FILE" ]; then
    log "Config não encontrada em $CONFIG_FILE"
    exit 1
fi

log "Iniciando snx-rs com config $CONFIG_FILE"

# snx-rs roda como daemon lendo o config.toml (server, usuário, tipo de auth,
# etc.). Se vocês usam SAML no Check Point também, o config.toml suporta
# auth-type = "saml" — veja a doc do snx-rs para o formato exato.
snx-rs --config-file "$CONFIG_FILE"
