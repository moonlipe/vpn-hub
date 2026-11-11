#!/bin/bash
set -euo pipefail

# openfortivpn com autenticação simples (usuário/senha), sem SAML/Chromium.
# Ativado com FORTI_AUTH=password no env file da instância.
#
# Variáveis:
#   VPN_GATEWAY         host ou host:porta (https:// é removido)  [obrigatória]
#   VPN_USERNAME        usuário                                    [obrigatória]
#   VPN_PASSWORD        senha                                      [obrigatória]
#   FORTI_TRUSTED_CERT  sha256 do certificado do gateway (se não for de CA pública)
#   FORTI_REALM         realm de autenticação (opcional)
#   FORTI_SET_DNS       1 = aplica DNS do gateway (padrão: 1)
#   FORTI_EXTRA_ARGS    flags extras repassadas ao openfortivpn
#   FORTI_RETRY_DELAY   segundos entre reconexões (padrão: 15)

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [forti-password] $*"
}

: "${VPN_GATEWAY:?VPN_GATEWAY não definida}"
: "${VPN_USERNAME:?VPN_USERNAME não definida}"
: "${VPN_PASSWORD:?VPN_PASSWORD não definida}"

RETRY_DELAY="${FORTI_RETRY_DELAY:-15}"

# Aceita "https://host:porta/qualquer" ou "host:porta" ou "host"
GW="${VPN_GATEWAY#https://}"
GW="${GW#http://}"
GW="${GW%%/*}"
HOST="${GW%%:*}"
PORT="443"
[[ "$GW" == *:* ]] && PORT="${GW##*:}"

# Credenciais num arquivo 600 em vez da linha de comando (não aparecem no ps)
CONFIG=/etc/openfortivpn/config
mkdir -p /etc/openfortivpn
umask 077
{
    echo "host = $HOST"
    echo "port = $PORT"
    echo "username = $VPN_USERNAME"
    echo "password = $VPN_PASSWORD"
    echo "set-dns = ${FORTI_SET_DNS:-1}"
    echo "pppd-use-peerdns = ${FORTI_SET_DNS:-1}"
    [ -n "${FORTI_TRUSTED_CERT:-}" ] && echo "trusted-cert = $FORTI_TRUSTED_CERT"
    [ -n "${FORTI_REALM:-}" ] && echo "realm = $FORTI_REALM"
} > "$CONFIG"

OFV_PID=""
trap 'log "Encerrando..."; [ -n "$OFV_PID" ] && kill -TERM "$OFV_PID" 2>/dev/null; wait; exit 0' SIGTERM SIGINT

# shellcheck disable=SC2206
EXTRA=(${FORTI_EXTRA_ARGS:-})

while true; do
    log "Conectando em $HOST:$PORT como $VPN_USERNAME..."
    openfortivpn -c "$CONFIG" "${EXTRA[@]}" &
    OFV_PID=$!
    wait "$OFV_PID" && rc=0 || rc=$?
    OFV_PID=""
    log "openfortivpn saiu (código $rc). Reconectando em ${RETRY_DELAY}s..."
    sleep "$RETRY_DELAY"
done
