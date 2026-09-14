#!/bin/bash
set -euo pipefail

LOG_DIR="/var/log/vpn-gateway"
mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [entrypoint] $*"
}

# Verifica se o container tem as capabilities necessárias
if [ ! -e /dev/net/tun ]; then
    log "ERRO FATAL: /dev/net/tun não encontrado."
    log "Rode o container com: --device /dev/net/tun --cap-add NET_ADMIN"
    exit 1
fi

PIDS=()

# Torna /etc/resolv.conf gravável — o snx-rs tenta escrever nele e o
# Podman rootless monta como read-only bind do host.
# Com --dns=none, o Podman não monta resolv.conf — criamos um novo.
if [ ! -w /etc/resolv.conf ]; then
    RESOLV_CONTENT=$(cat /etc/resolv.conf 2>/dev/null || true)
    rm -f /etc/resolv.conf 2>/dev/null || true
    if [ -n "$RESOLV_CONTENT" ]; then
        echo "$RESOLV_CONTENT" > /etc/resolv.conf
    else
        echo "nameserver 8.8.8.8" > /etc/resolv.conf
        echo "nameserver 8.8.4.4" >> /etc/resolv.conf
    fi
    log "/etc/resolv.conf tornado gravável"
fi

cleanup() {
    log "Recebido sinal de encerramento, derrubando túneis..."
    for pid in "${PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null || true
        fi
    done
    wait
    log "Todos os processos encerrados."
    exit 0
}
trap cleanup SIGTERM SIGINT

# ------------------------------------------------------------------
# Cada VPN é opcional: só sobe se a config correspondente existir.
# Isso permite usar a mesma imagem em cenários com 1, 2 ou 3 túneis.
# ------------------------------------------------------------------

if [ -n "${VPN_GATEWAY:-}" ] && [ -n "${VPN_USERNAME:-}" ] && [ -n "${VPN_PASSWORD:-}" ]; then
    log "Credenciais do daemon SAML presentes, iniciando openfortivpn..."
    # Garante que o diretório de estado persistente (sessão do Azure AD,
    # logs) pertence ao vpndaemon antes de trocar de usuário — importante
    # se ele veio montado como volume do host.
    mkdir -p /opt/vpn-daemon/.local/share/vpn-daemon
    chown -R vpndaemon:vpndaemon /opt/vpn-daemon/.local
    /usr/local/bin/start-forti-daemon.sh >> "$LOG_DIR/forti.log" 2>&1 &
    PIDS+=($!)
else
    log "VPN_GATEWAY/VPN_USERNAME/VPN_PASSWORD não definidas — pulando openfortivpn."
fi

if [ -f /etc/vpn-gateway/snx/config.toml ]; then
    if [ -n "${SNX_HEALTHCHECK_IP:-}" ]; then
        log "Config do snx-rs encontrada, iniciando com watchdog (IP: $SNX_HEALTHCHECK_IP)..."
        /usr/local/bin/snx-watchdog.sh >> "$LOG_DIR/snx-watchdog.log" 2>&1 &
    else
        log "Config do snx-rs encontrada, iniciando (sem watchdog)..."
        /usr/local/bin/start-snx.sh >> "$LOG_DIR/snx.log" 2>&1 &
    fi
    PIDS+=($!)
else
    log "Sem config em /etc/vpn-gateway/snx/config.toml — pulando snx-rs."
fi

if [ -f /etc/vpn-gateway/wireguard/wg0.conf ]; then
    log "Config do WireGuard encontrada, iniciando..."
    /usr/local/bin/start-wireguard.sh >> "$LOG_DIR/wireguard.log" 2>&1 &
    PIDS+=($!)
else
    log "Sem config em /etc/vpn-gateway/wireguard/wg0.conf — pulando WireGuard."
fi

# ------------------------------------------------------------------
# Port-forwards opcionais via socat (ex: expor RDP/DB de uma sub-rede
# atrás de um túnel numa porta local do host). Formato:
#   SOCAT_FORWARDS="porta_local:ip_destino:porta_destino,..."
# Cada forward roda como processo próprio, monitorado igual às VPNs —
# se o container reiniciar (--restart unless-stopped), o entrypoint
# roda de novo e recria todos os forwards.
# ------------------------------------------------------------------
if [ -n "${SOCAT_FORWARDS:-}" ]; then
    IFS=',' read -ra FORWARDS <<< "$SOCAT_FORWARDS"
    for fwd in "${FORWARDS[@]}"; do
        fwd="$(echo "$fwd" | xargs)"
        [ -z "$fwd" ] && continue
        local_port="${fwd%%:*}"
        target="${fwd#*:}"
        log "Iniciando socat: TCP-LISTEN:${local_port} -> TCP:${target}"
        socat "TCP-LISTEN:${local_port},fork,reuseaddr" "TCP:${target}" >> "$LOG_DIR/socat.log" 2>&1 &
        PIDS+=($!)
    done
else
    log "SOCAT_FORWARDS não definida — pulando port-forwards."
fi

if [ ${#PIDS[@]} -eq 0 ]; then
    log "ERRO: nenhuma VPN configurada. Monte pelo menos um arquivo de config."
    exit 1
fi

log "Túneis iniciados. Rotas ativas:"
sleep 5
ip route show || true
log "Interfaces de rede:"
ip -brief addr show || true

# Mantém o container vivo enquanto os processos filhos existirem
wait
log "Um dos processos de VPN encerrou inesperadamente — verifique os logs em $LOG_DIR"
cleanup
