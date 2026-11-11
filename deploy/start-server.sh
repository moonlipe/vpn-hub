#!/bin/bash
set -euo pipefail

# =============================================================
# start-server.sh — sobe/atualiza as VPNs no servidor via compose
# =============================================================
# Uso (em ~/vpn-hub, ao lado do compose.yaml). Rode no MESMO modo do
# setup antigo: se o container antigo rodava com sudo (rootful), use sudo.
#   bash start-server.sh               # pull + sobe/atualiza tudo
#   bash start-server.sh forti snx     # só esses serviços
#
# Só recria os containers cuja imagem ou config mudou; os demais
# túneis continuam de pé.
# =============================================================

cd "$(dirname "$0")"
log() { echo "[$(date '+%H:%M:%S')] $*"; }

[ -f compose.yaml ] || { echo "compose.yaml não encontrado — rode deploy/migrate-to-compose.sh primeiro"; exit 1; }
podman compose version >/dev/null 2>&1 || { echo "Sem provider de compose. Instale: sudo apt install -y podman-compose"; exit 1; }

# PPP para o openfortivpn (idempotente; já deve estar persistido no boot)
if [ ! -e /dev/ppp ] || [ ! -w /dev/ppp ]; then
    log "Preparando /dev/ppp..."
    sudo modprobe ppp_generic
    sudo chmod 666 /dev/ppp
fi

# Container único antigo ocupa as mesmas portas — remove se ainda existir
if podman container exists vpn-hub; then
    log "Removendo container antigo 'vpn-hub' (modelo de container único)..."
    podman rm -f vpn-hub >/dev/null
fi

log "Atualizando imagem..."
podman compose pull "$@"

log "Subindo serviços..."
podman compose up -d "$@"

# Religa os containers (restart: always) depois de reboot.
# Rootful (sudo) -> unit de sistema; rootless -> unit de usuário.
if [ "$(id -u)" -eq 0 ]; then
    SYSTEMCTL=(systemctl)
else
    SYSTEMCTL=(systemctl --user)
fi
if ! "${SYSTEMCTL[@]}" is-enabled podman-restart.service >/dev/null 2>&1; then
    log "Habilitando podman-restart.service (auto-start no boot)..."
    "${SYSTEMCTL[@]}" enable podman-restart.service || log "AVISO: não foi possível habilitar podman-restart.service"
fi

sleep 5
log "Status:"
podman compose ps
echo
echo "  Logs:       podman compose logs -f <serviço>"
echo "  Forti:      podman exec forti tail -f /var/log/vpn-hub/forti.log"
echo "  Interfaces: podman exec <container> ip -brief addr"
