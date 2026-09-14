# VPN Hub Unificado — Podman

Imagem container com **openfortivpn** (SAML/MFA via Playwright/Chromium headless), **snx-rs** (Check Point) e **WireGuard** — túneis simultâneos, cada um roteando apenas as sub-redes do cliente.

## Estrutura do projeto

```
vpners/
├── Dockerfile                    # Build multi-stage (snx-rs, openfortivpn, imagem final)
├── entrypoint.sh                 # Inicia todos os túneis + socat forwards
├── scripts/
│   ├── start-forti-daemon.sh     # Daemon Python (SAML/Chromium) como vpndaemon
│   ├── start-snx.sh              # snx-rs com config.toml
│   ├── snx-watchdog.sh           # Watchdog: monitora VPN e reinicia snx-rs
│   ├── start-wireguard.sh        # wg-quick up + monitoramento
│   └── healthcheck.sh            # Verifica interfaces ativas
├── vpn-daemon/                   # Clonado via CI (não versionado neste repo)
├── forti-daemon.env.example      # Template de credenciais openfortivpn
├── snx-config.example.toml       # Template config snx-rs
└── wg0.conf.example              # Template config WireGuard
```

## Pré-requisitos no host

- **Podman** (ou Docker)
- **`/dev/net/tun`** disponível
- **`/dev/ppp`** com permissão adequada

```bash
# Verificar e configurar PPP (necessário para openfortivpn)
sudo modprobe ppp_generic
sudo chmod 666 /dev/ppp

# Verificar
ls -la /dev/net/tun /dev/ppp
```

> **Rootless Podman**: o snx-rs precisa de `--privileged` porque escreve em `/proc/sys` para configurar XFRM. O entrypoint também lida com `/etc/resolv.conf` read-only usando `--dns=none`.

## Build da imagem

```bash
# Clone o vpn-daemon (repo público) na pasta do projeto
git clone https://github.com/moonlipe/openforti-saml-resolver.git vpn-daemon

# Build
podman build -t vpn-hub:latest .
```

Ou faça push no branch `main` — o GitHub Actions builda e publica em `ghcr.io/moonlipe/vpn-hub:latest` automaticamente.

## Configuração

### openfortivpn (SAML)

```bash
cp forti-daemon.env.example forti-daemon.env
chmod 600 forti-daemon.env
# Preencha VPN_GATEWAY, VPN_USERNAME, VPN_PASSWORD
```

### snx-rs (Check Point)

```bash
mkdir -p ~/vpn-configs/snx
cp snx-config.example.toml ~/vpn-configs/snx/config.toml
# Edite server-name, auth-type, routes
```

### WireGuard

```bash
mkdir -p ~/vpn-configs/wireguard
cp wg0.conf.example ~/vpn-configs/wireguard/wg0.conf
chmod 600 ~/vpn-configs/wireguard/wg0.conf
```

## Rodar

### Local (build + execução)

```bash
# Build e execução em um comando
./start.sh

# Ou manualmente
podman build -t vpn-hub:local .
podman run -d \
  --name vpn-hub \
  --privileged \
  --device /dev/net/tun \
  --device /dev/ppp \
  --sysctl net.ipv4.ip_forward=1 \
  --dns=none \
  --env-file forti-daemon.env \
  -e SOCAT_FORWARDS="4000:10.0.0.100:3389" \
  -v ~/vpn-configs/snx:/etc/vpn-hub/snx:Z \
  -v ~/vpn-configs/wireguard:/etc/vpn-hub/wireguard:Z \
  -v vpn-daemon-state:/opt/vpn-daemon/.local:Z \
  -p 4000:4000 \
  --restart unless-stopped \
  vpn-hub:local
```

### Servidor (Oracle Cloud)

```bash
# Usar start-gateway.sh (já configurado com paths do servidor)
./start-gateway.sh

# Ou manualmente
podman pull ghcr.io/moonlipe/vpn-hub:latest
podman run -d \
  --name vpn-hub \
  --privileged \
  --device /dev/net/tun \
  --device /dev/ppp \
  --sysctl net.ipv4.ip_forward=1 \
  --dns=none \
  --env-file ~/vpn-configs/forti-daemon.env \
  -e SOCAT_FORWARDS="4000:10.0.0.100:3389" \
  -v ~/vpn-configs/snx:/etc/vpn-hub/snx:Z \
  -v ~/vpn-configs/wireguard:/etc/vpn-hub/wireguard:Z \
  -v vpn-daemon-state:/opt/vpn-daemon/.local:Z \
  -p 4000:4000 \
  --restart unless-stopped \
  ghcr.io/moonlipe/vpn-hub:latest
```

Flags obrigatórias:
- `--privileged`: necessário para snx-rs escrever em `/proc/sys` (XFRM)
- `--device /dev/net/tun`: para criar interfaces de rede
- `--device /dev/ppp`: para o openfortivpn usar pppd
- `--dns=none`: evita que o Podman monte `/etc/resolv.conf` read-only (snx-rs tenta escrever nele)
- `--env-file`: credenciais nunca entram na imagem
- `vpn-daemon-state`: persiste sessão do navegador (evita MFA a cada restart)

## Port-forwards com socat

Exponha serviços de sub-redes atrás dos túneis:

```bash
# formato: porta_local:ip_destino:porta_destino (separados por vírgula)
-e SOCAT_FORWARDS="4000:10.0.0.100:3389,4010:10.0.0.200:3389"
-p 4000:4000 -p 4010:4010
```

## Watchdog snx-rs (auto-restart)

O snx-rs pode perder conectividade mesmo mantendo o processo ativo. O watchdog monitora a VPN via ping e reinicia automaticamente quando a conexão cai.

### Como funciona

1. A cada 120s, faz `ping` para um IP interno da VPN (`SNX_HEALTHCHECK_IP`)
2. Se o ping falhar ou o processo snx-rs morrer, reinicia automaticamente
3. Limite de 5 restarts em 10 minutos (evita loop infinito)
4. Logs em `/var/log/vpn-hub/snx-watchdog.log`

### Ativar

```bash
podman run -d \
  --name vpn-hub \
  --privileged \
  --device /dev/net/tun \
  --device /dev/ppp \
  --dns=none \
  -e SNX_HEALTHCHECK_IP="10.20.0.1" \
  -v ~/vpn-configs/snx:/etc/vpn-hub/snx:Z \
  ...
```

### Variáveis de ambiente

| Variável | Padrão | Descrição |
|---|---|---|
| `SNX_HEALTHCHECK_IP` | *(vazio)* | IP interno da VPN para ping. Se não definido, watchdog desabilitado |
| `SNX_CHECK_INTERVAL` | `120` | Intervalo entre checks (segundos) |
| `SNX_RESTART_LIMIT` | `5` | Máximo de restarts em 10 minutos |

### Sem watchdog

Se `SNX_HEALTHCHECK_IP` não estiver definido, o snx-rs roda normalmente sem monitoramento (comportamento anterior).

## Primeira execução (MFA)

1. Acompanhe os logs: `podman logs -f vpn-hub`
2. O daemon abre Chromium headless, navega para o gateway e aguarda MFA
3. Aprovação acontece no **celular** (Microsoft Authenticator) — confirme o número exibido no log
4. Após aprovação, sessão fica salva no volume `vpn-daemon-state`
5. Próximas reconexões (dentro da janela de 14 dias) não pedem MFA

> **Nota**: O seletor Microsoft para number-matching foi atualizado para `#idRichContext_DisplaySign` (a Microsoft mudou o DOM). Isso já está corrigido na versão mais recente da imagem.

### Modo debug (com screenshots)

```bash
podman run --rm -it \
  --privileged \
  --device /dev/net/tun \
  --device /dev/ppp \
  --dns=none \
  --env-file forti-daemon.env \
  -e VPN_SCREENSHOTS=1 -e VPN_DEBUG=1 \
  -v vpn-daemon-state:/opt/vpn-daemon/.local:Z \
  ghcr.io/moonlipe/vpn-hub:latest
```

Screenshots ficam em `/opt/vpn-daemon/.local/share/vpn-daemon/screenshots/` dentro do container.

## Verificar túneis

```bash
# Ver interfaces ativas (deve mostrar ppp0, snx-xfrm, wg0)
podman exec vpn-hub ip -brief addr show

# Verificar interface ppp0 especificamente
podman exec vpn-hub ip addr show ppp0

# Ver rotas ativas
podman exec vpn-hub ip route show

# Verificar logs do openfortivpn para confirmar tunnel
podman exec vpn-hub tail -f /opt/vpn-daemon/.local/share/vpn-daemon/openfortivpn_saml.log
```

## Logs

```bash
podman exec vpn-hub tail -f /var/log/vpn-hub/forti.log
podman exec vpn-hub tail -f /var/log/vpn-hub/snx.log
podman exec vpn-hub tail -f /var/log/vpn-hub/snx-watchdog.log
podman exec vpn-hub tail -f /var/log/vpn-hub/wireguard.log
podman exec vpn-hub tail -f /var/log/vpn-hub/socat.log
```

## Roteamento simultâneo

Cada VPN roteia **apenas** as sub-redes do seu cliente (`no-default-route` / `AllowedIPs` restrito), então as interfaces coexistem sem conflito. Se algum cliente exigir 0.0.0.0/0, será necessário policy routing com tabelas separadas + `ip rule`.

## Segurança

- Credenciais nunca entram na imagem — sempre via `--env-file`
- Daemon roda como `vpndaemon` (não-root) com sudo restrito ao `openfortivpn`
- `NET_ADMIN` é privilégio elevado — trate o host como perímetro de confiança
- Volume `vpn-daemon-state` guarda sessão de auth — trate como credencial

## Variáveis de ambiente

| Variável | Padrão | Descrição |
|----------|--------|-----------|
| `VPN_GATEWAY` | *(obrigatório)* | URL do gateway VPN (openfortivpn) |
| `VPN_USERNAME` | *(obrigatório)* | Usuário VPN |
| `VPN_PASSWORD` | *(obrigatório)* | Senha VPN |
| `VPN_HEADLESS` | `1` | Executar Chromium em modo headless |
| `VPN_DEBUG` | `0` | Ativar logs detalhados |
| `VPN_SCREENSHOTS` | `0` | Salvar screenshots do processo |
| `SNX_HEALTHCHECK_IP` | *(vazio)* | IP para ping de healthcheck (ativa watchdog) |
| `SNX_CHECK_INTERVAL` | `120` | Intervalo entre checks (segundos) |
| `SNX_RESTART_LIMIT` | `5` | Máximo de restarts em 10 minutos |
| `SOCAT_FORWARDS` | *(vazio)* | Port-forwards via socat (formato: `porta:ip:porta,...`) |

## Troubleshooting

| Erro | Causa | Solução |
|------|-------|---------|
| `Module ppp not found` | Módulo não carregado | `sudo modprobe ppp_generic` |
| `/dev/ppp: Permission denied` | Rootless mapeia como nobody | `sudo chmod 666 /dev/ppp` no host |
| `Couldn't open /dev/ppp` | Device não existe | `sudo modprobe ppp_generic` geralmente cria |
| `pppd: The kernel does not support PPP` | Módulo ppp_generic não carregado | `sudo modprobe ppp_generic` |
| MFA pede toda vez | Volume de sessão não persistente | Usar `-v vpn-daemon-state:/opt/vpn-daemon/.local:Z` |
| snx-xfrm cai | Config com login-type errado | Usar `vpn_Username_Password` (case-sensitive) |
| ppp0 não sobe | Permissão ou módulo | Verificar `modprobe` + `chmod` |
| chrome-error:// | Sessão SAML expirada | Deletar volume `vpn-daemon-state` e reiniciar |

## CI/CD

Push no branch `main` dispara build automático via GitHub Actions → publica em `ghcr.io/moonlipe/vpn-hub:latest`. No servidor, basta:

```bash
podman pull ghcr.io/moonlipe/vpn-hub:latest
podman rm -f vpn-hub
bash start-gateway.sh
```
