# Deploy na Oracle Cloud — Guia Específico

Guia completo para rodar o VPN Gateway em instâncias Oracle Cloud (E2 Micro, Ubuntu).

## Problema: kernel Oracle sem PPP

O kernel Oracle (`linux-oracle`) no x86_64 **remove os módulos PPP** propositalmente (cloud-optimized). O openfortivpn precisa do `pppd` que depende do módulo `ppp_generic` do kernel.

**Sintoma**: openfortivpn autentica via SAML, mas falha com:
```
Couldn't open the /dev/ppp device: No such file or directory
pppd: The kernel does not support PPP
```

**Solução**: trocar para o kernel genérico Ubuntu.

### 1. Instalar kernel genérico

```bash
sudo apt update
sudo apt install linux-generic
```

Isso instala o kernel `6.8.x` genérico com todos os módulos PPP.

### 2. Configurar GRUB para bootar o genérico

```bash
# Ver entries do GRUB
sudo grep -E 'menuentry|submenu' /boot/grub/grub.cfg | cat -n

# Definir o genérico como default (ajuste o número conforme output acima)
# Geralmente: submenu "Advanced options" = entry 1, genérico = posição 4
sudo sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT="1>4"/' /etc/default/grub
sudo update-grub

# Reiniciar
sudo reboot
```

### 3. Verificar

```bash
uname -r                          # deve mostrar 6.8.0-xxx-generic
sudo modprobe ppp_generic          # deve funcionar sem erro
ls /lib/modules/$(uname -r)/kernel/drivers/net/ppp/  # deve listar ppp_async.ko, etc.
```

### 4. Garantir que o módulo carrega no boot

```bash
echo ppp_generic | sudo tee /etc/modules-load.d/ppp.conf
```

## Problema: /dev/ppp com permissão errada

Mesmo com o módulo carregado, o `pppd` pode falhar com **"Permission denied"** porque o podman rootless mapeia o device com ownership `nobody:nogroup`.

**Sintoma**:
```
Couldn't open the /dev/ppp device: Permission denied
```

**Solução**: corrigir as permissões **no host** antes de iniciar o container. O `chmod` dentro do container rootless não funciona (o podman impede alterar permissões de devices mapeados).

```bash
# Corrigir agora
sudo chmod 666 /dev/ppp

# Para persistir no boot
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

## mknod para /dev/ppp (se necessário)

Se o `/dev/ppp` não existir no host:

```bash
sudo mknod /dev/ppp c 108 0
sudo chmod 666 /dev/ppp
```

Para persistir no boot, crie um service systemd:

```bash
sudo cat > /etc/systemd/system/dev-ppp.service << 'EOF'
[Unit]
Description=Create /dev/ppp device
Before=network.target

[Service]
Type=oneshot
ExecStart=/bin/mknod -m 666 /dev/ppp c 108 0
ExecStartPost=/bin/chmod 666 /dev/ppp
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable dev-ppp.service
```

## start.sh completo (referência)

```bash
#!/bin/bash
set -euo pipefail

SOCAT_FORWARDS="4000:10.0.0.100:3389,4001:10.0.0.100:19990,4002:10.0.0.100:18766,4010:10.0.0.200:3389,4020:10.0.0.201:3389"

podman rm -f vpn-gateway 2>/dev/null || true

podman run -d \
  --name vpn-gateway \
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
  ghcr.io/moonlipe/vpn-gateway:latest
```

## Troubleshooting rápido

| Erro | Causa | Solução |
|------|-------|---------|
| `Module ppp not found` | Kernel Oracle sem PPP | Trocar para kernel genérico (`linux-generic`) |
| `/dev/ppp: Permission denied` | Rootless mapeia como nobody | `sudo chmod 666 /dev/ppp` no host |
| `Couldn't open /dev/ppp: No such file` | Device não existe no host | `sudo mknod /dev/ppp c 108 0` |
| `pppd: The kernel does not support PPP` | Módulo ppp_generic não carregado | `sudo modprobe ppp_generic` |
| MFA pede toda vez | Volume de sessão não persistente | Usar `-v vpn-daemon-state:/opt/vpn-daemon/.local:Z` |
| snx-xfrm cai | Config com login-type errado | Usar `vpn_Username_Password` (case-sensitive) |
