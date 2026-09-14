# Deploy na Oracle Cloud — Guia Específico

Guia completo para rodar o VPN Gateway em instâncias Oracle Cloud (E2 Micro, Ubuntu).

## PPP no Oracle Cloud

O kernel Oracle (`linux-oracle`) **já inclui** o módulo `ppp_generic`, mas ele precisa ser carregado manualmente. Não é necessário trocar de kernel.

### 1. Carregar módulo e liberar permissão

```bash
# Carregar módulo PPP
sudo modprobe ppp_generic

# Liberar permissão (o device /dev/ppp já existe após o modprobe)
sudo chmod 666 /dev/ppp

# Verificar
ls -la /dev/ppp
```

### 2. Persistir no boot

```bash
# Carregar módulo automaticamente
echo ppp_generic | sudo tee /etc/modules-load.d/ppp.conf

# Service para garantir permissão do /dev/ppp no boot
sudo tee /etc/systemd/system/dev-ppp-permissions.service << 'EOF'
[Unit]
Description=Fix /dev/ppp permissions for rootless podman
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/chmod 666 /dev/ppp
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable dev-ppp-permissions.service
```

### 3. Verificar

```bash
uname -r                          # kernel Oracle (ex: 6.17.0-xxx-oracle)
sudo modprobe ppp_generic          # deve funcionar sem erro
ls -la /dev/ppp                    # deve existir com permissão 666
```

## Container auto-start no reboot

### Opção 1: `--restart unless-stopped` (mais simples)

Adicione `--restart unless-stopped` no `podman run`. O podman gerencia o restart automaticamente.

### Opção 2: systemd user service (mais robusto)

```bash
mkdir -p ~/.config/systemd/user/

cat > ~/.config/systemd/user/vpn-gateway.service << 'EOF'
[Unit]
Description=VPN Gateway Container
After=network-online.target

[Service]
Restart=always
ExecStart=/usr/bin/podman start -a vpn-gateway
ExecStop=/usr/bin/podman stop vpn-gateway
TimeoutStopSec=30

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable vpn-gateway.service

# Habilitar lingering (pra rodar sem estar logado)
sudo loginctl enable-linger ubuntu
```

## start-gateway.sh completo (servidor)

```bash
#!/bin/bash
set -euo pipefail

# ============================================================
# start-gateway.sh — Execução no servidor (Oracle Cloud)
# ============================================================

CONTAINER_NAME="vpn-gateway"
IMAGE="ghcr.io/moonlipe/vpn-gateway:latest"

SOCAT_FORWARDS="4000:10.0.0.100:3389,4001:10.0.0.100:19990,4002:10.0.0.100:18766,4010:10.0.0.200:3389,4020:10.0.0.201:3389"

# Puxar imagem mais recente
echo "[$(date '+%H:%M:%S')] Pulling $IMAGE ..."
podman pull "$IMAGE"

# Parar container antigo se existir
podman rm -f "$CONTAINER_NAME" 2>/dev/null || true

# Subir container
echo "[$(date '+%H:%M:%S')] Iniciando container..."
podman run -d \
  --name "$CONTAINER_NAME" \
  --privileged \
  --device /dev/net/tun \
  --device /dev/ppp \
  --sysctl net.ipv4.ip_forward=1 \
  --dns=none \
  --env-file ~/vpn-configs/forti-daemon.env \
  -e SOCAT_FORWARDS="$SOCAT_FORWARDS" \
  -v ~/vpn-configs/snx:/etc/vpn-gateway/snx:Z \
  -v ~/vpn-configs/wireguard:/etc/vpn-gateway/wireguard:Z \
  -v vpn-daemon-state:/opt/vpn-daemon/.local:Z \
  -p 4000:4000 \
  -p 4001:4001 \
  -p 4002:4002 \
  -p 4010:4010 \
  -p 4020:4020 \
  --restart unless-stopped \
  "$IMAGE"

echo "[$(date '+%H:%M:%S')] OK."
echo "  podman logs -f $CONTAINER_NAME"
echo "  podman exec $CONTAINER_NAME tail -f /var/log/vpn-gateway/snx-watchdog.log"
```

## Flags obrigatórias

| Flag | Motivo |
|------|--------|
| `--privileged` | snx-rs escreve em `/proc/sys` para configurar XFRM (rootless Podman) |
| `--device /dev/net/tun` | Interfaces de rede tuneladas |
| `--device /dev/ppp` | openfortivpn usa pppd para criar ppp0 |
| `--dns=none` | Evita que o Podman monte `/etc/resolv.conf` read-only (snx-rs tenta escrever) |
| `--env-file` | Credenciais nunca entram na imagem |
| `-v vpn-daemon-state:...` | Persiste sessão do navegador (evita MFA a cada restart) |

## Troubleshooting rápido

| Erro | Causa | Solução |
|------|-------|---------|
| `Module ppp not found` | Módulo não carregado | `sudo modprobe ppp_generic` |
| `/dev/ppp: Permission denied` | Rootless mapeia como nobody | `sudo chmod 666 /dev/ppp` no host |
| `Couldn't open /dev/ppp: No such file` | Device não existe | `sudo modprobe ppp_generic` (geralmente cria o device) |
| `pppd: The kernel does not support PPP` | Módulo ppp_generic não carregado | `sudo modprobe ppp_generic` |
| MFA pede toda vez | Volume de sessão não persistente | Usar `-v vpn-daemon-state:/opt/vpn-daemon/.local:Z` |
| snx-xfrm cai | Config com login-type errado | Usar `vpn_Username_Password` (case-sensitive) |
| ppp0 não sobe | Permissão ou módulo | Verificar `modprobe` + `chmod` |
