#!/bin/bash
set -euo pipefail

# Watchdog para snx-rs: monitora conectividade via ping e reinicia
# quando a VPN cai. Protege contra loop infinito com limite de restarts.

CONFIG_FILE="/etc/vpn-hub/snx/config.toml"
CHECK_INTERVAL="${SNX_CHECK_INTERVAL:-120}"
RESTART_LIMIT="${SNX_RESTART_LIMIT:-5}"
RESTART_WINDOW=600  # janela de 10 minutos para contar restarts
PING_TIMEOUT=3
PING_COUNT=1

SNX_PID=""
RESTART_COUNT=0
RESTART_WINDOW_START=0
LAST_LOG_FILE="/var/log/vpn-hub/snx-watchdog.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [snx-watchdog] $*"
}

cleanup() {
    log "Recebido sinal de encerramento, matando snx-rs..."
    if [ -n "$SNX_PID" ] && kill -0 "$SNX_PID" 2>/dev/null; then
        kill -TERM "$SNX_PID" 2>/dev/null || true
        wait "$SNX_PID" 2>/dev/null || true
    fi
    log "Watchdog encerrado."
    exit 0
}
trap cleanup SIGTERM SIGINT

reset_restart_counter() {
    local now
    now=$(date +%s)
    if [ $((now - RESTART_WINDOW_START)) -ge $RESTART_WINDOW ]; then
        RESTART_COUNT=0
        RESTART_WINDOW_START=$now
    fi
}

can_restart() {
    reset_restart_counter
    if [ "$RESTART_COUNT" -ge "$RESTART_LIMIT" ]; then
        return 1
    fi
    return 0
}

start_snx() {
    log "Iniciando snx-rs..."
    /usr/local/bin/start-snx.sh >> /var/log/vpn-hub/snx.log 2>&1 &
    SNX_PID=$!
    log "snx-rs iniciado com PID $SNX_PID"
}

check_snx_alive() {
    if [ -z "$SNX_PID" ]; then
        return 1
    fi
    kill -0 "$SNX_PID" 2>/dev/null
}

check_connectivity() {
    if [ -z "${SNX_HEALTHCHECK_IP:-}" ]; then
        return 0  # sem IP configurado, assume OK
    fi
    ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$SNX_HEALTHCHECK_IP" &>/dev/null
}

restart_snx() {
    if ! can_restart; then
        log "ERRO: Limite de $RESTART_LIMIT restarts em 10 minutos atingido. Watchdog parado."
        log "Verifique a conectividade da VPN manualmente."
        # Mantém o watchdog vivo mas sem reiniciar — permite diagnóstico
        return 1
    fi

    RESTART_COUNT=$((RESTART_COUNT + 1))
    log "Reiniciando snx-rs (tentativa $RESTART_COUNT/$RESTART_LIMIT)..."

    # Mata processo existente
    if [ -n "$SNX_PID" ] && kill -0 "$SNX_PID" 2>/dev/null; then
        kill -TERM "$SNX_PID" 2>/dev/null || true
        wait "$SNX_PID" 2>/dev/null || true
        sleep 2
    fi

    start_snx
    sleep 5  # dá tempo para a interface subir
    return 0
}

# --- Main ---

if [ ! -f "$CONFIG_FILE" ]; then
    log "ERRO: Config não encontrada em $CONFIG_FILE"
    exit 1
fi

if [ -z "${SNX_HEALTHCHECK_IP:-}" ]; then
    log "SNX_HEALTHCHECK_IP não definida — watchdog desabilitado, executando snx-rs direto"
    exec /usr/local/bin/start-snx.sh
fi

log "Watchdog habilitado. IP de checagem: $SNX_HEALTHCHECK_IP"
log "Intervalo: ${CHECK_INTERVAL}s | Limite restarts: $RESTART_LIMIT em 10min"

start_snx
RESTART_WINDOW_START=$(date +%s)

while true; do
    sleep "$CHECK_INTERVAL"

    # Verifica se o processo snx-rs ainda está vivo
    if ! check_snx_alive; then
        log "WARN: Processo snx-rs encerrou inesperadamente"
        if ! restart_snx; then
            break
        fi
        continue
    fi

    # Verifica conectividade via ping
    if ! check_connectivity; then
        log "WARN: Conectividade perdida para $SNX_HEALTHCHECK_IP"
        if ! restart_snx; then
            break
        fi
        continue
    fi

    log "OK: snx-rs ativo e conectivo"
done
