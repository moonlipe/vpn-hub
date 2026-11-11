#!/bin/bash
set -euo pipefail

# =============================================================
# migrate-to-rootless.sh — move o compose de rootful (sudo) para rootless
# =============================================================
# Rode como o usuário normal (SEM sudo), em ~/vpn-hub, ao lado do
# compose.yaml. O script chama sudo só onde precisa.
#
# O que faz:
#   1. pré-requisitos do podman rootless (uidmap, subuid/subgid, compose)
#   2. /dev/ppp acessível (modprobe + chmod 666)
#   3. copia volumes do root para o usuário (sessão Azure AD → sem novo MFA)
#   4. derruba os containers rootful e desativa o auto-start do root
#   5. libera no iptables as portas publicadas no compose.yaml
#      (rootless escuta direto no host → passa pela chain INPUT, que o
#      firewall padrão da Oracle bloqueia; rootful usava DNAT e não passava)
#   6. linger + podman-restart.service de usuário (auto-start no boot)
#   7. sobe tudo rootless via start-server.sh
# =============================================================

cd "$(dirname "$0")"
log() { echo "[$(date '+%H:%M:%S')] [rootless] $*"; }
die() { echo "ERRO: $*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "rode como usuário normal, sem sudo (o script pede sudo quando precisa)"
[ -f compose.yaml ] || die "compose.yaml não encontrado em $(pwd)"
[ -f start-server.sh ] || die "start-server.sh não encontrado em $(pwd)"

# ---------- 1. Pré-requisitos ----------
command -v newuidmap >/dev/null || { log "Instalando uidmap..."; sudo apt-get install -y uidmap; }
if ! grep -q "^$USER:" /etc/subuid || ! grep -q "^$USER:" /etc/subgid; then
    log "Configurando subuid/subgid para $USER..."
    sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"
    podman system migrate
fi
podman compose version >/dev/null 2>&1 || { log "Instalando podman-compose..."; sudo apt-get install -y podman-compose; }
podman info >/dev/null 2>&1 || die "podman rootless não funciona: rode 'podman info' para ver o erro (no Ubuntu 24.04, veja kernel.apparmor_restrict_unprivileged_userns)"

# ---------- 2. PPP ----------
log "Preparando /dev/ppp..."
sudo modprobe ppp_generic
sudo chmod 666 /dev/ppp

# ---------- 3. Volumes do root → usuário ----------
for vol in $(sudo podman volume ls -q); do
    if podman volume exists "$vol"; then
        log "Volume '$vol' já existe no rootless — mantendo"
        continue
    fi
    log "Copiando volume '$vol' do root para o usuário..."
    tmp="$(mktemp)"
    sudo podman volume export "$vol" -o "$tmp"
    sudo chown "$USER:" "$tmp"
    podman volume create "$vol" >/dev/null
    podman volume import "$vol" "$tmp"
    rm -f "$tmp"
done
# (o entrypoint faz chown do estado do forti para o vpndaemon ao subir)

# ---------- 4. Desliga o rootful ----------
log "Derrubando containers rootful..."
sudo podman compose down 2>/dev/null || true
sudo podman rm -f vpn-hub 2>/dev/null || true
if systemctl is-enabled podman-restart.service >/dev/null 2>&1; then
    log "Desativando podman-restart.service do root..."
    sudo systemctl disable podman-restart.service
fi
sudo chown -R "$USER:" .

# ---------- 5. Firewall ----------
PORTS="$(grep -oE '^[[:space:]]*-[[:space:]]*"?[0-9]+:[0-9]+' compose.yaml | grep -oE '[0-9]+:' | tr -d ':' | sort -un)"
CHANGED=0
for p in $PORTS; do
    if ! sudo iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null; then
        sudo iptables -I INPUT -p tcp --dport "$p" -j ACCEPT
        CHANGED=1
    fi
done
log "Portas liberadas no INPUT: $(echo $PORTS)"
if [ "$CHANGED" = 1 ]; then
    if command -v netfilter-persistent >/dev/null; then
        sudo netfilter-persistent save
        log "Regras persistidas (netfilter-persistent)"
    else
        log "AVISO: netfilter-persistent ausente — as regras somem no reboot (sudo apt install iptables-persistent)"
    fi
fi

# ---------- 6. Auto-start no boot ----------
sudo loginctl enable-linger "$USER"

# ---------- 7. Sobe rootless ----------
log "Subindo rootless..."
bash start-server.sh
