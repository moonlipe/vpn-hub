# AGENTS.md — Guia Técnico para Agentes de IA

Referência rápida para trabalhar neste projeto. Evita ler README/DEPLOY na íntegra.

## Visão Geral

Container Podman unificado com 3 VPNs simultâneas:
- **openfortivpn** — SAML/MFA via Playwright/Chromium headless → interface `ppp0`
- **snx-rs** — Check Point VPN → interface `snx-xfrm`
- **WireGuard** → interfaces `wg*` (uma por arquivo .conf)

Cada VPN rota apenas as sub-redes do seu cliente (sem conflito).

## Estrutura

```
vpners/
├── Dockerfile                    # Build multi-stage: snx-rs (Rust) + openfortivpn (C) + imagem final
├── entrypoint.sh                 # Orchestrador: sobe VPNs + socat, mantém container vivo
├── start.sh                      # LOCAL: build + run (gitignored)
├── scripts/
│   ├── start-forti-daemon.sh     # Executa vpn_daemon.py como vpndaemon via gosu
│   ├── start-snx.sh              # snx-rs (sem exec — watchdog pode gerenciar)
│   ├── snx-watchdog.sh           # Watchdog: ping healthcheck, restart com limite
│   ├── start-wireguard.sh        # wg-quick up por config + monitoramento
│   └── healthcheck.sh            # Verifica interfaces ativas
├── vpn-daemon/                   # Clonado via CI de moonlipe/openforti-saml-resolver (gitignored)
│   └── vpn_daemon.py             # Daemon Python: Playwright + openfortivpn SAML
├── forti-daemon.env.example      # Template: VPN_GATEWAY, VPN_USERNAME, VPN_PASSWORD
├── snx-config.example.toml       # Template config snx-rs
├── wireguard.conf.example       # Template config WireGuard
└── .github/workflows/build-push.yml  # CI: build → ghcr.io/moonlipe/vpn-gateway:latest
```

## Arquivos Críticos

### `entrypoint.sh`
- Cria `/etc/resolv.conf` gravável (com `--dns=none`)
- Sobe VPNs condicionalmente (só se config existir)
- Watchdog snx-rs condicional (só se `SNX_HEALTHCHECK_IP` definido)
- socat forwards via `SOCAT_FORWARDS` (formato: `porta:ip:porta,...`)
- `wait` mantém container vivo; cleanup mata processos filhos

### `vpn-daemon/vpn_daemon.py`
- Abre Chromium headless, navega para gateway SAML
- Microsoft MFA number-matching: seletor `#idRichContext_DisplaySign` (LINHA 288)
- Regex fallback: `(?:número|number|digite|enter)\s+(\d{2,3})` (LINHA 294)
- Volume `vpn-daemon-state` persiste sessão Azure AD (evita MFA a cada restart)
- Logs em `/var/log/vpn-hub/forti.log`

### `scripts/snx-watchdog.sh`
- Ping a cada 120s no `SNX_HEALTHCHECK_IP`
- Restart automático se falhar, limite 5 em 10min
- Logs em `/var/log/vpn-hub/snx-watchdog.log`

## Configuração

### Diretórios no servidor (`~/vpn-hub/`)
```
vpn-configs/
├── forti-daemon.env          # Credenciais openfortivpn
├── snx/config.toml           # Config snx-rs
└── wireguard/wg0.conf        # Config WireGuard
```

### Variáveis de Ambiente

| Variável | Obrigatória | Descrição |
|----------|-------------|-----------|
| `VPN_GATEWAY` | openfortivpn | URL do gateway |
| `VPN_USERNAME` | openfortivpn | Usuário |
| `VPN_PASSWORD` | openfortivpn | Senha |
| `SNX_HEALTHCHECK_IP` | snx-rs watchdog | IP para ping (ativa watchdog) |
| `SOCAT_FORWARDS` | optional | Port-forwards (`4000:10.0.0.100:3389,...`) |
| `VPN_DEBUG` | optional | Logs detalhados |
| `VPN_SCREENSHOTS` | optional | Salva screenshots do Chromium |

### Flags Podman (OBRIGATÓRIAS)

```
--privileged          # snx-rs escreve em /proc/sys (XFRM)
--device /dev/net/tun # interfaces tuneladas
--device /dev/ppp     # openfortivpn usa pppd
--dns=none            # resolv.conf gravável (snx-rs escreve nele)
--env-file            # credenciais nunca na imagem
```

## Servidor vs Local

| | Local | Servidor (Oracle) |
|---|---|---|
| Script | `start.sh` (build + run) | `start-gateway.sh` (pull + run) |
| Imagem | `vpn-gateway:local` | `ghcr.io/moonlipe/vpn-gateway:latest` |
| Config | `./vpn-config/` | `~/vpn-configs/` |
| Env file | `./vpn-config/forti-daemon.env` | `~/vpn-configs/forti-daemon.env` |

## Correções Aplicadas (não reverter)

1. **MFA selector**: `#idRichContext_DisplaySignNumber` → `#idRichContext_DisplaySign` (Microsoft mudou o DOM)
2. **Regex MFA**: `[^\d]{0,40}` → `\s` (pula newline entre label e número)
3. **snx-watchdog**: sem `tee -a` (evita log duplicado)
4. **PPP no Oracle**: `modprobe ppp_generic` + `chmod 666` (NÃO precisa trocar kernel)
5. **start-snx.sh**: sem `exec` (watchdog precisa controlar o processo)

## Comandos Úteis

```bash
# Status
podman exec vpn-hub ip -brief addr show    # interfaces ativas
podman exec vpn-hub ip route show          # rotas
podman exec vpn-hub tail -f /var/log/vpn-hub/forti.log  # openfortivpn
podman exec vpn-hub tail -f /opt/vpn-daemon/.local/share/vpn-daemon/openfortivpn_saml.log

# Debug
podman exec vpn-hub cat /opt/vpn-daemon/.local/share/vpn-daemon/openfortivpn_saml.log

# Reiniciar
podman rm -f vpn-hub && bash start-gateway.sh  # servidor
podman rm -f vpn-hub && bash start.sh          # local

# PPP (servidor)
sudo modprobe ppp_generic
sudo chmod 666 /dev/ppp
```

## Troubleshooting Rápido

| Erro | Solução |
|------|---------|
| `Module ppp not found` | `sudo modprobe ppp_generic` |
| `/dev/ppp: Permission denied` | `sudo chmod 666 /dev/ppp` |
| `pppd: The kernel does not support PPP` | `sudo modprobe ppp_generic` |
| `VPN não subiu — ppp0` | Verificar openfortivpn_saml.log |
| `chrome-error://` | Sessão expirada, deletar volume vpn-daemon-state |
| MFA `500` em vez de número | Selector antigo, rebuildar imagem |
| snx-xfrm cai | Verificar config: `vpn_Username_Password` (case-sensitive) |

## CI/CD

Push no `main` → GitHub Actions → `ghcr.io/moonlipe/vpn-gateway:latest`
- CI clona `vpn-daemon` de `moonlipe/openforti-saml-resolver`
- Local: `vpn-daemon/` é gitignored, clonar manualmente para build

## Azure AD

- Sessão salva em `vpn-daemon-state` (volume persistente)
- Janela MFA: ~14 dias sem pedir novamente
