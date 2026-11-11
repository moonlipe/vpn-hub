#!/bin/bash
set -euo pipefail

# =============================================================
# migrate-to-compose.sh — gera compose.yaml a partir do setup antigo
# =============================================================
# Roda NO SERVIDOR, em ~/vpn-hub, com o container antigo (vpn-hub)
# ainda de pé e com as VPNs conectadas.
#
# Para cada forward do SOCAT_FORWARDS, pergunta ao container antigo
# por qual interface o IP de destino sai (ip route get) e coloca o
# forward no serviço da VPN correspondente:
#   ppp*                         → forti      (vpn-configs/forti-daemon.env)
#   <nome>.conf em wireguard/    → wg-<nome>  (vpn-configs/wireguard/<nome>.conf)
#   qualquer outra (snx-xfrm...) → snx        (vpn-configs/snx/config.toml)
#
# SOCAT_FORWARDS e SNX_HEALTHCHECK_IP vêm do ambiente ou, se não
# definidos, são lidos do start-server.sh antigo.
#
# Não altera nada além de criar compose.yaml e .env (aborta se já
# existirem, a menos que FORCE=1).
# =============================================================

OLD_CONTAINER="${OLD_CONTAINER:-vpn-hub}"
OLD_SCRIPT="${OLD_SCRIPT:-./start-server.sh}"
CONFIG_DIR="${CONFIG_DIR:-./vpn-configs}"
IMAGE="${VPN_HUB_IMAGE:-ghcr.io/moonlipe/vpn-hub:latest}"
OUT="compose.yaml"

die() { echo "ERRO: $*" >&2; exit 1; }
info() { echo "[migrate] $*"; }

read_var_from_script() {
    # extrai VAR="valor" do script antigo sem executá-lo
    sed -n "s/^$1=\"\(.*\)\"$/\1/p" "$OLD_SCRIPT" | head -1
}

if [ -z "${SOCAT_FORWARDS:-}" ] && [ -f "$OLD_SCRIPT" ]; then
    SOCAT_FORWARDS="$(read_var_from_script SOCAT_FORWARDS)"
fi
if [ -z "${SNX_HEALTHCHECK_IP+x}" ] && [ -f "$OLD_SCRIPT" ]; then
    SNX_HEALTHCHECK_IP="$(read_var_from_script SNX_HEALTHCHECK_IP)"
fi
SOCAT_FORWARDS="${SOCAT_FORWARDS:-}"
SNX_HEALTHCHECK_IP="${SNX_HEALTHCHECK_IP:-}"

[ "${FORCE:-0}" = "1" ] || [ ! -e "$OUT" ] || die "$OUT já existe (use FORCE=1 para sobrescrever)"
podman container exists "$OLD_CONTAINER" || die "container '$OLD_CONTAINER' não encontrado — ele precisa estar rodando para detectar as rotas"
[ "$(podman inspect -f '{{.State.Running}}' "$OLD_CONTAINER")" = "true" ] || die "container '$OLD_CONTAINER' não está rodando"

# ---------- Descobre as VPNs configuradas ----------
HAS_FORTI=0; HAS_SNX=0; WG_IFACES=()
[ -f "$CONFIG_DIR/forti-daemon.env" ] && HAS_FORTI=1
[ -f "$CONFIG_DIR/snx/config.toml" ] && HAS_SNX=1
for f in "$CONFIG_DIR"/wireguard/*.conf; do
    [ -e "$f" ] && WG_IFACES+=("$(basename "$f" .conf)")
done
info "VPNs encontradas: forti=$HAS_FORTI snx=$HAS_SNX wireguard=${WG_IFACES[*]:-nenhuma}"

# ---------- Classifica cada forward pela interface de saída ----------
declare -A FWD   # serviço → "fwd1,fwd2,..."
FAILED=0

service_for_dev() {
    local dev="$1" wg
    case "$dev" in
        ppp*) [ "$HAS_FORTI" = 1 ] && { echo forti; return; } ;;
        eth*|lo|"") echo ""; return ;;
    esac
    for wg in "${WG_IFACES[@]}"; do
        [ "$dev" = "$wg" ] && { echo "wg-$wg"; return; }
    done
    [ "$HAS_SNX" = 1 ] && { echo snx; return; }
    echo ""
}

if [ -n "$SOCAT_FORWARDS" ]; then
    IFS=',' read -ra FWDS <<< "$SOCAT_FORWARDS"
    for fwd in "${FWDS[@]}"; do
        fwd="$(echo "$fwd" | xargs)"
        [ -z "$fwd" ] && continue
        target="${fwd#*:}"; ip="${target%%:*}"
        dev="$(podman exec "$OLD_CONTAINER" ip route get "$ip" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)"
        svc="$(service_for_dev "$dev")"
        if [ -z "$svc" ]; then
            echo "  ✗ $fwd → interface '${dev:-?}' (não é VPN — túnel caído?)" >&2
            FAILED=1
            continue
        fi
        echo "  ✓ $fwd → $dev → $svc"
        FWD[$svc]="${FWD[$svc]:+${FWD[$svc]},}$fwd"
    done
fi
[ "$FAILED" = 0 ] || die "alguns destinos não saem por nenhuma VPN. Verifique se todos os túneis estão de pé (podman exec $OLD_CONTAINER ip -brief addr) e rode de novo."

# ---------- Gera compose.yaml ----------
emit_forwards() {
    local svc="$1" list="${FWD[$1]:-}" f
    [ -z "$list" ] && return
    echo "      SOCAT_FORWARDS: \"$list\""
}
emit_ports() {
    local list="${FWD[$1]:-}" f
    [ -z "$list" ] && return
    echo "    ports:"
    IFS=',' read -ra L <<< "$list"
    for f in "${L[@]}"; do echo "      - \"${f%%:*}:${f%%:*}\""; done
}

{
cat <<EOF
# Gerado por deploy/migrate-to-compose.sh em $(date '+%Y-%m-%d %H:%M')
# Um container por VPN. Para adicionar instâncias veja os modelos no fim.

x-vpn-base: &vpn-base
  image: \${VPN_HUB_IMAGE:-$IMAGE}
  restart: always
  privileged: true
  devices:
    - /dev/net/tun
  sysctls:
    net.ipv4.ip_forward: "1"

x-forti-base: &forti-base
  <<: *vpn-base
  devices:
    - /dev/net/tun
    - /dev/ppp

services:
EOF

if [ "$HAS_FORTI" = 1 ]; then
cat <<EOF
  forti:
    <<: *forti-base
    container_name: forti
    env_file: $CONFIG_DIR/forti-daemon.env
EOF
[ -n "${FWD[forti]:-}" ] && { echo "    environment:"; emit_forwards forti; }
emit_ports forti
cat <<EOF
    volumes:
      # volume de sessão Azure AD já existente (não pede MFA de novo)
      - vpn-daemon-state:/opt/vpn-daemon/.local

EOF
fi

if [ "$HAS_SNX" = 1 ]; then
cat <<EOF
  snx:
    <<: *vpn-base
    container_name: snx
EOF
if [ -n "$SNX_HEALTHCHECK_IP" ] || [ -n "${FWD[snx]:-}" ]; then
    echo "    environment:"
    [ -n "$SNX_HEALTHCHECK_IP" ] && echo "      SNX_HEALTHCHECK_IP: \"$SNX_HEALTHCHECK_IP\""
    emit_forwards snx
fi
emit_ports snx
cat <<EOF
    volumes:
      - $CONFIG_DIR/snx/config.toml:/etc/vpn-hub/snx/config.toml:ro,Z

EOF
fi

for wg in "${WG_IFACES[@]}"; do
cat <<EOF
  wg-$wg:
    <<: *vpn-base
    container_name: wg-$wg
EOF
[ -n "${FWD[wg-$wg]:-}" ] && { echo "    environment:"; emit_forwards "wg-$wg"; }
emit_ports "wg-$wg"
cat <<EOF
    volumes:
      - $CONFIG_DIR/wireguard/$wg.conf:/etc/vpn-hub/wireguard/$wg.conf:ro,Z

EOF
done

cat <<EOF
  # ---------------------------------------------------------------
  # MODELOS — descomente e ajuste para novas instâncias
  # (portas do host não podem repetir entre serviços)
  # ---------------------------------------------------------------
  # forti-cliente-x:              # openforti só usuário/senha
  #   <<: *forti-base
  #   container_name: forti-cliente-x
  #   env_file: $CONFIG_DIR/forti/cliente-x.env   # com FORTI_AUTH=password
  #   environment:
  #     SOCAT_FORWARDS: "4050:10.0.0.10:3389"
  #   ports:
  #     - "4050:4050"
  #
  # forti-cliente-y:              # outro openforti SAML
  #   <<: *forti-base
  #   container_name: forti-cliente-y
  #   env_file: $CONFIG_DIR/forti/cliente-y.env
  #   volumes:
  #     - forti-cliente-y-state:/opt/vpn-daemon/.local   # declarar em volumes:
  #
  # wg-cliente-z:
  #   <<: *vpn-base
  #   container_name: wg-cliente-z
  #   volumes:
  #     - $CONFIG_DIR/wireguard/cliente-z.conf:/etc/vpn-hub/wireguard/wg0.conf:ro,Z

volumes:
  vpn-daemon-state:
    external: true
EOF
} > "$OUT"

[ -e .env ] || echo "VPN_HUB_IMAGE=$IMAGE" > .env

info "compose.yaml gerado. Revise com: cat $OUT"
info "Próximo passo: bash start-server.sh  (novo, baseado em compose)"
