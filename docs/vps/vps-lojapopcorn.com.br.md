# VPS lojapopcorn.com.br — inventário completo e guia de migração

> ### 🔄 A migração já foi executada — 09/AGO/2026
>
> A VPS nova está pronta e verificada. **Este documento passa a ser o registro histórico
> da máquina antiga**; o operacional agora é
> **[vps-chico-figueiredo.com.br.md](vps-chico-figueiredo.com.br.md)**, que traz o estado
> atual e o procedimento de cutover.
>
> Esta VPS **continua em produção e intacta** até o DNS virar. O que mudou aqui: apenas
> uma chave SSH de migração acrescentada em `/root/.ssh/authorized_keys` (restrita a
> `from="191.252.219.183"`, com backup em `authorized_keys.bak-pre-migracao`) — remover
> depois do cutover.
>
> ### ⚠️ Incidente: o banco do basilioimoveis.com.br foi apagado por ransomware
>
> Em **04/JUL/2026 às 23:30**, via phpMyAdmin exposto em `0.0.0.0:8095`. O site responde
> 500 desde então. Detalhes, alcance verificado e decisão tomada: §8 do documento novo.
> As seções §5, §7.1 e §12 abaixo descrevem a exposição que foi explorada.

> **Levantamento feito em 09/AGO/2026** direto do servidor (`root@ssh.lojapopcorn.com.br`).
> Serve para dois propósitos: (a) saber exatamente o que existe hoje na DigitalOcean e
> (b) reconstruir a mesma coisa na VPS nova da Locaweb, no mesmo espírito do passo a passo
> de 30/MAI/2024 que criou este servidor.
>
> Documento de referência original: [DigitalOcean NYC 30MAI2024 -LojaPopCorn NGINX Load Balancer.html](../evernote/DigitalOcean%20NYC%2030MAI2024%20-LojaPopCorn%20NGINX%20Load%20Balancer/DigitalOcean%20NYC%2030MAI2024%20-LojaPopCorn%20NGINX%20Load%20Balancer.html)

---

## ⚠️ Sobre segredos

**Nenhuma senha, chave ou token está escrito neste documento.** Onde havia segredo, há um
ponteiro para onde ele mora. Isto é proposital: este repositório é um backup de
*configuração*, e configuração vai para o git — segredo, não.

| Segredo | Onde está hoje |
|---|---|
| Senha root do servidor | BitWarden |
| Chave SSH do root | `/root/.ssh/id_rsa` (par usado nos remotes git) |
| Senhas MySQL/Redis das apps | dentro dos `docker-compose.yaml`, já versionados nos repos GitLab de cada app |
| `.env` do hermes/Beth | `/opt/hermes-agent/home/.env` e `deploy/.env` — **fora do git de propósito** (ver [RESTORE.md](#7-hermes--beth-bethchicofigueiredocombr)) |
| `.env` do aritmética | `/opt/lojapopcorn/aritmetica-instrumental-landing-page/app/server/.env` |
| Senhas dos painéis (basic auth) | bcrypt em `/etc/nginx/focus.htpasswd` e `/etc/nginx/ia-monitor.htpasswd` |
| Chaves privadas dos túneis | na **máquina de casa**: `~/.ssh/focus_tunel` e `~/.ssh/ia_monitor_tunel` |

Ao migrar, **copie os `.env` por canal seguro (scp direto máquina→máquina), nunca por git.**

---

## 1. Ficha técnica do servidor atual

| Item | Valor |
|---|---|
| Provedor | DigitalOcean — droplet criado em 30/MAI/2024 |
| Hostname | `lojapopcorn.com.br` |
| IP público | `167.99.225.233` |
| IP privado (VPC) | `10.116.0.3` (eth1) · `10.10.0.6` (eth0, rede antiga) |
| SO | Ubuntu **24.04.4 LTS** (Noble Numbat), kernel 6.8.0-137 |
| CPU / RAM | **2 vCPU / 3.8 GB** · **sem swap** |
| Disco raiz | `/dev/vda1` — **24 GB**, 15 GB usados (64%) |
| Volume anexado | `/dev/sda` — **10 GB** em `/opt/lojapopcorn`, 3.8 GB usados (41%) |
| Timezone | `America/Sao_Paulo` · NTP ativo |
| Locale | `C.UTF-8` |
| Docker | 28.1.1 · Compose v2.35.1 |
| Nginx | 1.24.0 (pacote Ubuntu) |
| Certbot | plugin nginx, renovação por cron **e** timer |
| Uptime típico | reboots ocasionais (25 no histórico do bash) |

**Volume montado via `/etc/fstab`:**

```
/dev/disk/by-id/scsi-0DO_Volume_lojapopcorn-vol /opt/lojapopcorn ext4 defaults,nofail,discard 0 0
```

> 💡 **Na Locaweb esse `by-id` não existe.** É um nome de dispositivo específico da DigitalOcean.
> Se a VPS nova tiver disco adicional, use o **UUID** (`blkid`) em vez do `by-id`. Se for disco
> único, o mais simples é **abandonar a separação** e deixar tudo em `/opt/lojapopcorn` no disco
> raiz — o conteúdo real que precisa migrar é ~1.5 GB (ver §11).

**Agentes específicos da DigitalOcean que NÃO devem ir para a Locaweb:**
`do-agent.service`, `droplet-agent.service`, `droplet-agent-update.timer`, `/opt/digitalocean/` (27 MB).

---

## 2. Mapa geral — o que responde onde

```
                          Internet
                             │
                    ┌────────┴────────┐
                    │  nginx :80/:443 │  ← TLS Let's Encrypt em todos
                    └────────┬────────┘
   ┌──────────────┬──────────┼──────────┬───────────────┬──────────────┐
   │              │          │          │               │              │
basilio        bolao     aritmética   api(proxy)     links(estático)  túneis SSH
:8085          :5001     :11808/:3001  → openrouter   /opt/site-...    reversos
   │              │          │                                          │
wordpress+     node14+    react+node                            ┌───────┴───────┐
mysql5.7+      redis                                            │               │
phpmyadmin                                                   :17788          :21985
                                                             focus-scrap    ia-monitor
                                                                  └── PC de casa ──┘
                                                    (+ beth :8787 → hermes-agent :8642)
```

### Tabela mestra

| # | Domínio | nginx (arquivo) | Upstream | Onde roda | Vive em |
|---|---|---|---|---|---|
| 1 | `basilioimoveis.com.br` ⚠️ **HTTP 500** | `basilioimoveis.com.br` | `localhost:8085` | Docker (3 containers) | `/opt/lojapopcorn/site-basilio-imoveis` |
| 2 | `bolao.maxmat1.com.br` | `bolao.maxmat1.com.br` | `localhost:5001` | Docker (2 containers) | `/opt/lojapopcorn/bolao.maxmat1.com.br` |
| 3 | `aritmeticainstrumental.com.br` (+7 aliases) | `aritmeticainstrumental.com.br` | `:11808` e `/api → :3001` | Docker (2 containers) | `/opt/lojapopcorn/aritmetica-instrumental-landing-page/app` |
| 4 | `api.lojapopcorn.com.br` | `api.lojapopcorn.com.br` | **proxy reverso p/ openrouter.ai** | só nginx | — |
| 5 | `links.corretora-de-tenis.com.br` (+2) | `corretora-de-tenis-sites` | arquivos estáticos | só nginx | `/opt/site-redirecionamento-corretora` |
| 6 | `beth.chicofigueiredo.com.br` | `beth.chicofigueiredo.com.br.conf` | `127.0.0.1:8787` | Docker (2 containers) | `/opt/hermes-agent` |
| 7 | `focus.chicofigueiredo.com.br` | `focus.chicofigueiredo.com.br` | `127.0.0.1:17788` | **PC de casa** (túnel SSH) | `D:\Chico\focus-scrap` |
| 8 | `ia-monitor.chicofigueiredo.com.br` | `ia-monitor.chicofigueiredo.com.br` | `127.0.0.1:21985` | **PC de casa** (túnel SSH) | `D:\Chico\ia-monitor` |
| 9 | `_` (default) | `default` | `/var/www/html` | só nginx | — |

**Serviço extra sem domínio:** `ftp-anon` (vsftpd anônimo) nas portas 21/115/8080/8443 —
**em loop de reinício há meses** (196 restarts, exit code 2). Ver §9.

---

## 3. DNS — o que precisa mudar no cutover

Levantamento de 09/AGO/2026 (`dig @1.1.1.1`):

| Nome | Resolve para | Tipo |
|---|---|---|
| `lojapopcorn.com.br` | `167.99.225.233` | A |
| `ssh.lojapopcorn.com.br` | CNAME → `nova.lojapopcorn.com.br` → `167.99.225.233` | **CNAME** |
| `api.lojapopcorn.com.br` | CNAME → `lojapopcorn.com.br` | CNAME |
| `basilioimoveis.com.br` | `167.99.225.233` | A |
| `bolao.maxmat1.com.br` | CNAME → `maxmat1.com.br` → `167.99.225.233` | CNAME |
| `aritmeticainstrumental.com.br` | `167.99.225.233` | A |
| `www.aritmeticainstrumental.com.br` | CNAME → `aritmeticainstrumental.com.br` | CNAME |
| `chicofigueiredo.com.br` **e `*.chicofigueiredo.com.br`** | `167.99.225.233` | A + **curinga** |
| `chico.mat.br` | `167.99.225.233` | A |
| `links.daipipoka.com.br` | CNAME → `daipipoka.com.br` → `167.99.225.233` | CNAME |
| `links.corretora-de-tenis.com.br` | **não resolve** | ❌ morto |
| `links.corretoradetenis.com.br` | **não resolve** | ❌ morto |
| `chico-figueiredo.com.br` | `191.252.219.183` | **já é Locaweb** — outro servidor |

**Nameservers:** `chicofigueiredo.com.br` está na **DigitalOcean** (`ns1/ns2/ns3.digitalocean.com`).
`lojapopcorn.com.br` e `maxmat1.com.br` estão no **Registro.br** com DNSSEC (`*.sec.dns.br`).

> 🔑 **Duas alavancas de cutover:**
> 1. `nova.lojapopcorn.com.br` é o registro A por trás do `ssh.` — trocar ele muda o acesso SSH.
> 2. **Enquanto a zona `chicofigueiredo.com.br` estiver nos NS da DigitalOcean, você depende da DO
>    mesmo depois de desligar o droplet.** Migre a zona (DO → Locaweb ou Cloudflare) **antes** de
>    encerrar a conta, ou 3 sites (beth, focus, ia-monitor) e o curinga inteiro caem junto.
>
> 💡 **Baixe o TTL para 300s uns 2 dias antes do cutover.** Depois de estável, volte para 3600s.

---

## 4. Nginx — configuração global

`/etc/nginx/nginx.conf`, o que foge do padrão:

```nginx
server_names_hash_bucket_size 256;   # subiu de 64 → 256: são muitos server_name
```

**Sites habilitados: 9** (symlinks em `sites-enabled/` → `sites-available/`).
**Sites disponíveis mas NÃO habilitados:** `links-sites` (versão antiga do corretora-de-tenis),
`api.lojapopcorn.com.br.bak-20260628232613` (backup).

**Certificados Let's Encrypt (8 nomes, todos válidos em 09/AGO/2026):**

| Certificado | Domínios cobertos | Expira |
|---|---|---|
| `api.lojapopcorn.com.br` | 1 | 27/SET/2026 |
| `aritmeticainstrumental.com.br` | **8** (incl. aliases `.chico.mat.br`, `.chicofigueiredo.com.br`) | 25/SET/2026 |
| `basilioimoveis.com.br` | 1 | 19/OUT/2026 |
| `beth.chicofigueiredo.com.br` | 1 | 07/NOV/2026 |
| `bolao.maxmat1.com.br` | 1 | 19/OUT/2026 |
| `focus.chicofigueiredo.com.br` | 1 | 05/NOV/2026 |
| `ia-monitor.chicofigueiredo.com.br` | 1 | 06/NOV/2026 |
| `links.corretora-de-tenis.com.br` | 3 (2 já sem DNS) | 29/SET/2026 |

**Renovação — está duplicada** (funciona, mas é redundante):
- `crontab -l` do root: `0 12 * * * /usr/bin/certbot renew --quiet && systemctl reload nginx`
- `/etc/cron.d/certbot` (do pacote) + `certbot.timer` (systemd)

> 💡 Na VPS nova, **fique só com o `certbot.timer`** e adicione o hook de reload:
> `certbot renew --deploy-hook "systemctl reload nginx"`.

**Logs por site:** `beth.access.log`, `beth.error.log`, `corretora-de-tenis-sites.access.log`.
Os demais caem no `access.log` global. `/var/log` está com **2.7 GB** — vale revisar o logrotate.

---

## 5. Firewall (UFW)

```
Status: active   |   Default: deny (incoming), allow (outgoing), deny (routed)

22/tcp            ALLOW IN    Anywhere      # SSH
80/tcp            ALLOW IN    Anywhere      # HTTP
443               ALLOW IN    Anywhere      # HTTPS
80,443/tcp        ALLOW IN    Anywhere      # perfil "Nginx Full" (redundante)
21/tcp            ALLOW IN    Anywhere      # FTP        ⚠️ ver §9
8080/tcp          ALLOW IN    Anywhere      # FTP alt    ⚠️
30091:30100/tcp   ALLOW IN    Anywhere      # PASV range ⚠️
31000:31009/tcp   ALLOW IN    Anywhere      # PASV range ⚠️
```

> ⚠️ **As regras 21, 8080 e as duas faixas 30091–30100 / 31000–31009 existem só para o
> `ftp-anon`, que está quebrado.** Na VPS nova, **não recrie nenhuma delas** a menos que o FTP
> volte a ser necessário — e se voltar, que não seja anônimo com escrita.

**Portas realmente escutando hoje:**

| Porta | Quem | Exposição |
|---|---|---|
| 22 | sshd | pública |
| 80, 443 | nginx | pública |
| 3001 | aritmética server | **0.0.0.0 — desnecessário**, só nginx usa |
| 5001 | bolão | **0.0.0.0 — desnecessário** |
| 6379 | redis do bolão | **0.0.0.0 — Redis exposto na internet** ⚠️ |
| 8085 | wordpress basilio | **0.0.0.0 — desnecessário** |
| 8095 / 8096 | phpMyAdmin | **0.0.0.0 — phpMyAdmin exposto** ⚠️ |
| 11808 | aritmética client | **0.0.0.0 — desnecessário** |
| 8787 | hermes-webui | `127.0.0.1` ✅ |
| 8642 | hermes-agent | `127.0.0.1` ✅ |
| 17788 | ponta do túnel focus | `127.0.0.1` ✅ |
| 21985 | ponta do túnel ia-monitor | `127.0.0.1` ✅ |

> 🔒 O UFW **não** bloqueia essas portas porque o Docker escreve direto no `iptables`,
> abaixo do UFW. Redis com senha e phpMyAdmin ficam alcançáveis de fora hoje.
> **Na VPS nova, prefixe `127.0.0.1:` em todo `ports:` de compose que só o nginx consome** —
> é como o hermes já faz. Ver §12.
>
> 🚨 **Isto não era hipótese: foi explorado.** O phpMyAdmin em `0.0.0.0:8095` sobe com
> `PMA_USER` e `PMA_PASSWORD` no compose, então quem abrisse `http://167.99.225.233:8095`
> caía **já autenticado** no banco. Em 04/JUL/2026 um bot apagou o banco do WordPress e
> deixou um pedido de resgate. Na VPS nova o phpMyAdmin não foi recriado e nenhuma porta
> de aplicação é alcançável de fora.

---

## 6. SSH — acessos e túneis

**Configuração efetiva:**

```
Port 22
PermitRootLogin yes
PasswordAuthentication no      # só chave (definido 2× em sshd_config.d/)
PubkeyAuthentication yes
AllowTcpForwarding yes         # ← indispensável para os túneis
GatewayPorts no                # ← correto: as pontas ficam só em 127.0.0.1
```

**Chaves autorizadas no root (6):** `chico@xCerebro` ×2, `chico@CEREBRO` ×3, `root@edusebrae` ×1.

**Usuários de serviço** — todos com `/usr/sbin/nologin`:

| Usuário | UID | Para quê |
|---|---|---|
| `tunel` | 1000 | túnel reverso do **focus-scrap**, porta 17788 |
| `tunel-ia` | 1001 | túnel reverso do **ia-monitor**, porta 21985 |
| `hermes` | 1002 | dono de `/opt/hermes-agent`, roda o `hermes-sync.timer` |

As chaves dos túneis vêm **trancadas** no `authorized_keys` — este é o detalhe que faz o
arranjo ser seguro e precisa ser reproduzido igual:

```
restrict,port-forwarding,permitlisten="17788",permitlisten="localhost:17788",permitlisten="127.0.0.1:17788" ssh-ed25519 AAAA... focus-tunel@wsl
restrict,port-forwarding,permitlisten="21985",permitlisten="localhost:21985",permitlisten="127.0.0.1:21985" ssh-ed25519 AAAA... ia-monitor-tunel@CEREBRO
```

`restrict` = sem shell, sem agent forwarding, sem X11, sem TTY. `permitlisten` = não consegue
abrir túnel em nenhuma outra porta. De posse dessa chave, o que se alcança é um painel que
**ainda pede senha**.

---

## 7. Inventário Docker

**4 projetos compose + 1 container avulso.** 12 imagens, 6.4 GB (1.3 GB recuperável).

### 7.1 `site-basilio-imoveis` — WordPress

📁 `/opt/lojapopcorn/site-basilio-imoveis` · 1.3 GB · repo `git@gitlab.com:basilio-imoveis/site-basilio-imoveis.git`

| Container | Imagem | Porta | Volume |
|---|---|---|---|
| `wordpress.basilio` | `wordpress:latest` | 8085→80 | `./wordpress:/var/www/html` (701 MB) |
| `db.basilio` | `mysql:5.7` | interna | `./mysql:/var/lib/mysql` (127 MB) |
| `phpmyadmin.basilio` | `phpmyadmin:latest` | 8095→80, 8096→443 | — |

Rede `rede-basilio` (bridge). Senhas em texto no `docker-compose.yaml` (já versionado no GitLab).
Também há `./plugins` (46 MB) e `./logo` (808 KB) fora dos volumes montados.

> ⚠️ **`mysql:5.7` está fora de suporte desde outubro/2023.** A migração é a hora natural de subir
> para 8.0 — mas **teste antes**: WordPress antigo + plugins podem quebrar. Se não der, migre
> como está e agende o upgrade em separado. Não misture os dois riscos no mesmo cutover.

### 7.2 `bolaomaxmat1combr` — Bolão

📁 `/opt/lojapopcorn/bolao.maxmat1.com.br` · 111 MB · repo `git@gitlab.com:maxmat1/bolao.maxmat1.com.br.git` (branch `master`)

| Container | Imagem | Porta |
|---|---|---|
| `bolao.maxmat1.com.br` | `node/bolao...` (build local, `FROM node:14`) | 5001→8081 |
| `cache.bolao.maxmat1.com.br` | `redis:7.2-alpine3.18` | 6379→6379 |

Rede `rede-maxmat1`. Volumes bind: `./app-build`, `./process`, `./tmp`, `./cache-redis`.

Rebuild (`rebuild-docker.sh`):
```sh
git pull origin master && git reset --hard origin/master
docker compose down && docker system prune -f
docker compose up -d --build --force-recreate --always-recreate-deps
```

> ⚠️ `node:14` chegou ao fim da vida em abril/2023. Constrói e roda, mas é dívida conhecida.
> Existe ainda `/opt/lojapopcorn/bolao.maxmat1.com.br-clone` (69 MB, último commit ABR/2025),
> **não usado por nenhum container** — não migre.

### 7.3 `app` — Aritmética Instrumental

📁 `/opt/lojapopcorn/aritmetica-instrumental-landing-page/app` · 2.7 MB
repo `git@gitlab.com:e-matematica/landing-pages/aritmetica-instrumental-landing-page.git`

| Container | Build | Porta |
|---|---|---|
| `aritmetica-instrumental-client` | `./client` (React/Vite + nginx) | 11808→80 |
| `aritmetica-instrumental-server` | `./server` (Node) | 3001→3001 |

`server/.env` (**não versionado**) tem: `SUPABASE_URL`, `SUPABASE_KEY`, `RESEND_API_KEY`,
`TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`. **Copie manualmente.**

### 7.4 `hermes` — Beth

📁 `/opt/hermes-agent` · 54 MB · repo `git@github.com:ChicoFigueiredo/hermes-agent.git` — espelhado em `D:\Chico\hermes-agent`

| Container | Imagem | Porta |
|---|---|---|
| `hermes-agent` | `nousresearch/hermes-agent:v2026.8.3` | `127.0.0.1:8642` |
| `hermes-webui` | `ghcr.io/nesquena/hermes-webui@sha256:d132c7c3…` (pinado por digest) | `127.0.0.1:8787` |

Volume nomeado `hermes_hermes-agent-src`. Bind mounts de `home/` e `workspace/`.

**Este projeto já tem o próprio runbook de desastre** — [`deploy/RESTORE.md`](https://github.com/ChicoFigueiredo/hermes-agent/blob/main/deploy/RESTORE.md),
meta de 30 min. Na migração, **siga aquele documento**, não improvise. Resumo:

```bash
git clone git@github.com:ChicoFigueiredo/hermes-agent.git /opt/hermes-agent
sudo /opt/hermes-agent/deploy/scripts/bootstrap.sh   # cria user hermes, nginx, timer
# repor home/.env e deploy/.env do BitWarden; chmod 600
docker compose -f /opt/hermes-agent/deploy/compose.yml up -d
certbot --nginx -d beth.chicofigueiredo.com.br
docker compose -f deploy/compose.yml exec hermes-agent hermes whatsapp   # re-parear QR
```

> ⚠️ **O WhatsApp precisa ser re-pareado à mão** — a sessão Baileys nunca vai para o git.
> Com `WHATSAPP_ENABLED=true` e sessão ausente, o gateway **encerra e derruba o Telegram junto**.
> Se não puder parear na hora, ponha `WHATSAPP_ENABLED=false` e suba o Telegram primeiro.

> ⚠️ **Nunca troque a tag do agente sem apagar o volume**: `hermes_hermes-agent-src` é
> inicializado no primeiro `up` e reusado mesmo depois de `docker pull`.

**Timer de sincronização** (`/etc/systemd/system/hermes-sync.{service,timer}`) — a cada 30 min,
`Persistent=true`, roda como user `hermes` com deploy key de escrita, commitando skills/memórias
de volta no GitHub. É o que faz a Beth "fazer backup de si mesma".

### 7.5 `ftp-anon` — avulso e quebrado

Criado por `/opt/lojapopcorn/ftp/open-ftp.sh` (`docker run` direto, sem compose).
`instantlinux/vsftpd`, anônimo com upload liberado, portas 21/115/8080/8443,
`ftp-data` em `chmod 777`.

**Estado: `Restarting (2)`, 196 reinícios, sem logs.** Diretório de dados vazio.
→ **Não migrar.** Ver §12.

---

## 8. Sites acoplados que rodam na sua máquina (não na VPS)

Estes três não são "sites da VPS" — a VPS é só o **cano com TLS e senha na ponta**.
O software roda no PC de casa e chega ao servidor por túnel SSH reverso que **o próprio PC disca**
(saindo pela porta 22). Sem porta aberta no roteador, sem IP fixo — funciona atrás do NAT da operadora.

```
tablet/celular ──HTTPS──▶ nginx na VPS ──▶ 127.0.0.1:PORTA (ponta do túnel)
                          (TLS + senha)              ▲
                                                     │ túnel SSH reverso
                              WSL/PC de casa ── ssh -R ┘
                                    │
                                    └─ painel em 127.0.0.1:PORTA
```

| | **focus-scrap** | **ia-monitor** |
|---|---|---|
| Pasta local | `D:\Chico\focus-scrap` | `D:\Chico\ia-monitor` |
| Domínio | `focus.chicofigueiredo.com.br` | `ia-monitor.chicofigueiredo.com.br` |
| Usuário do túnel | `tunel` | `tunel-ia` |
| **Porta (fixa dos dois lados)** | **17788** | **21985** |
| Senha (bcrypt) | `/etc/nginx/focus.htpasswd` | `/etc/nginx/ia-monitor.htpasswd` |
| Usuário do basic auth | `chico` | `chico` |
| Serviço local (systemd user) | `focus-tunel.service` | serviço do `4-servico-local.sh` |
| Rotas bloqueadas (403) | `/api/run`, `/api/requeue`, `/api/revelar`, `/api/abrir`, `/api/sincronizar` | `/api/login`, `/api/descobrir` |
| Scripts de instalação | `infra/remote/` (5 scripts numerados) | `infra/remote/` (5 scripts numerados) |

### Refazer na VPS nova

Cada projeto tem os scripts prontos e **idempotentes**. Em ambos, edite `config.sh` (trocando o
host para a VPS nova) e rode na ordem:

```bash
cd infra/remote
./1-chave-local.sh      # par de chaves exclusivo do túnel (aqui)
./2-droplet-usuario.sh  # usuário sem shell + chave trancada (lá)
./3-droplet-nginx.sh    # site, htpasswd, certbot (lá) — imprime a senha UMA vez
./4-servico-local.sh    # o túnel como serviço do systemd (aqui)
./verificar.sh          # confere a corrente elo por elo
```

> ⚠️ **Use usuários separados.** O passo 2 **sobrescreve** o `authorized_keys` de quem receber.
> Reaproveitar `tunel` para os dois derruba o focus-scrap sem aviso nenhum.

> ⚠️ **A porta é fixa e vive em dois lugares.** No focus-scrap ela está em `.env`
> (`FOCUS_PANEL_PORT=17788`) e em `config.sh`. Mudou uma, mude a outra e rode `3-` e `4-` de novo.
> Painel em porta diferente = túnel entrega em porta vazia = **502**.

> 💡 **502 é o comportamento esperado com o PC desligado.** Não é bug da VPS.
> Diagnóstico: `./verificar.sh` · `systemctl --user status focus-tunel` · `ss -lntp 'sport = :17788'`.

> 💡 **`focus-painel.service` existe mas não está instalado** — com ele, o painel sobe junto
> com o WSL e "PC ligado" já basta para o tablet enxergar.

### E o `chico-vps`?

`D:\Chico\chico-vps` **é este repositório**. Não tem nada rodando na VPS — é o backup
documental da configuração dela. Nada a instalar no servidor novo.

---

## 9. Cron, timers e serviços

**Cron do root:** só um — o `certbot renew` das 12h.
**`/etc/cron.d/`:** `certbot`, `e2scrub_all`, `sysstat` (todos de pacote).
**Nenhum cron nos usuários** `hermes`, `tunel`, `tunel-ia`, `www-data`.

**Timers systemd relevantes:**

| Timer | O quê | Migrar? |
|---|---|---|
| `hermes-sync.timer` | sincroniza estado da Beth com GitHub, 30/30 min | ✅ (via `bootstrap.sh`) |
| `certbot.timer` | renovação TLS | ✅ |
| `droplet-agent-update.timer` | atualiza agente DigitalOcean | ❌ |
| `apt-daily`, `logrotate`, `fstrim`, `man-db`, `sysstat` | padrão Ubuntu | ✅ automático |

**Serviços customizados em `/etc/systemd/system/`:** só `hermes-sync.{service,timer}`.
Os outros (`do-agent`, `droplet-agent*`) são DigitalOcean. **Nenhum serviço em estado `failed`.**

**Snaps instalados:** `canonical-livepatch`, `core22`, `snapd`.
→ O livepatch é serviço Ubuntu Pro; verifique se faz sentido na Locaweb.

---

## 10. Pastas sem serviço ativo (decidir antes de copiar)

| Pasta | Tamanho | O que é | Migrar? |
|---|---|---|---|
| `/opt/lojapopcorn/moddle-sebrae-backup` | **2.4 GB** | 5 dumps do Moodle SEBRAE, o mais novo de OUT/2024 | ❌ arquivo morto — mova para armazenamento frio |
| `/opt/lojapopcorn/bolao.maxmat1.com.br-clone` | 69 MB | clone antigo do bolão, ABR/2025 | ❌ |
| `/opt/lojapopcorn/mail` | 896 KB | `docker-mailserver` para `edu-sebrae.com.br`, **nunca subiu** (container não existe) | ❌ (guarde o `compose.yaml` se quiser retomar) |
| `/opt/lojapopcorn/ftp` | 24 KB | vsftpd anônimo quebrado, `ftp-data` vazio | ❌ |
| `/opt/lojapopcorn/lost+found` | 16 KB | do ext4 | ❌ |
| `/opt/git-corretora-tenis` | 1.7 MB | repo-fonte do site estático de links | ✅ (é a fonte de `/opt/site-redirecionamento-corretora`) |
| `/opt/site-redirecionamento-corretora` | 696 KB | HTML servido em `links.*` | ✅ — mas 2 dos 3 domínios já não resolvem |

**Os 2.4 GB do Moodle são 63% de tudo que está no volume.** Tirando eles, o servidor
inteiro cabe folgado em qualquer plano.

---

## 11. O que realmente precisa ser copiado

| Origem | Tamanho | Como |
|---|---|---|
| `/opt/lojapopcorn/site-basilio-imoveis/{wordpress,mysql,plugins,logo,php}` | **1.3 GB** | rsync com containers parados (ver §13) |
| `/opt/lojapopcorn/bolao.maxmat1.com.br` | 111 MB | `git clone` + rsync de `app-build`, `process`, `cache-redis` |
| `/opt/lojapopcorn/aritmetica-instrumental-landing-page` | 2.7 MB | `git clone` + `server/.env` |
| `/opt/hermes-agent/home/` (memórias, skills) | ~50 MB | `git clone` + `.env` + sessão WhatsApp |
| `/opt/site-redirecionamento-corretora` + `/opt/git-corretora-tenis` | 2.4 MB | `git clone` |
| `/etc/nginx/sites-available/*` | 52 KB | copiar e ajustar |
| `/etc/nginx/*.htpasswd` | 134 B | copiar (mantém as senhas atuais) |
| `/etc/letsencrypt/` | ~1 MB | **opcional** — mais limpo é reemitir com certbot depois do DNS |
| `.env` diversos | — | **canal seguro, nunca git** |

**Total real: ~1.5 GB.**

> 💡 **Dimensionamento da VPS nova:** o consumo real hoje é 1.3 GB de RAM com tudo no ar e
> ~5 GB de dados úteis. Um plano **2 vCPU / 4 GB / 40–50 GB SSD** cobre com folga.
> **Configure swap** (a VPS atual não tem — 2 GB já ajudam num build de imagem).

---

## 12. Correções que valem fazer *durante* a migração

A migração é a única hora em que corrigir isso não custa downtime extra.

1. **Fechar as portas dos containers.** Prefixe `127.0.0.1:` em todo `ports:` que só o nginx
   consome — `8085`, `8095`, `8096`, `5001`, `3001`, `11808` e principalmente **`6379` (Redis)**.
   Passa a ficar assim: `- "127.0.0.1:8085:80"`. O hermes já faz isso e é o modelo a copiar.
2. **Não recriar o `ftp-anon`** nem as regras de UFW 21 / 8080 / 30091-30100 / 31000-31009.
3. **phpMyAdmin:** se precisar dele, ponha atrás de basic auth no nginx, como focus/ia-monitor.
   Se não precisar, não suba.
4. **Criar swap** (2 GB).
5. **Uma renovação de certificado só** — `certbot.timer` com `--deploy-hook`, apagando o cron do root.
6. **Deixar `moddle-sebrae-backup` para trás** (arquivar em outro lugar).
7. **Limpar o Docker antes de medir**: `docker system prune -a` libera 1.3 GB de imagens órfãs.
8. **Investigar `/var/log` com 2.7 GB** — logrotate mais agressivo no `access.log`.
9. **`PermitRootLogin`**: hoje é `yes` com senha desabilitada (aceitável). Se quiser endurecer,
   `prohibit-password` é o equivalente explícito.
10. **Considerar `mysql:8.0`** no basilio — mas em janela separada do cutover.

---

## 13. Passo a passo — construir a VPS nova (Locaweb)

> Nos moldes do documento de 30/MAI/2024, atualizado para 2026 (o `apt-key` de lá está
> **deprecado** e o repositório Docker mudou de formato).

### 13.1 Primeiro acesso e identidade

```bash
# Enviar sua chave (se a Locaweb não injetou na criação)
cat ~/.ssh/id_rsa.pub | ssh root@IP_NOVO "mkdir -p ~/.ssh && cat - >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"

# Hostname
hostnamectl set-hostname lojapopcorn.com.br
nano /etc/hosts        # acrescente a linha do novo IP

# Timezone e locale
timedatectl set-timezone America/Sao_Paulo
timedatectl                     # conferir

# Chave para o git (usada nos remotes GitLab/GitHub)
ssh-keygen -t ed25519 -C "root@vps-locaweb"
cat /root/.ssh/id_ed25519.pub   # cadastrar em GitLab e GitHub
```

> 💡 A VPS atual usa `id_rsa` (2024). Na nova, prefira **ed25519** — menor e mais rápida.
> Lembre de cadastrar a pública nos **dois** provedores: há repos no GitLab e no GitHub.

### 13.2 Atualização e pacotes base

```bash
apt update && apt -y upgrade && apt -y dist-upgrade && apt -y autoremove

apt -y install zip unzip cpulimit lynx ncdu apt-transport-https ca-certificates \
               curl p7zip-full p7zip-rar software-properties-common apache2-utils \
               duf git git-lfs lftp htop

duf      # visão dos discos
ncdu /   # navegar consumo
```

### 13.3 Swap (a VPS atual não tem — crie na nova)

```bash
fallocate -l 2G /swapfile && chmod 600 /swapfile
mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
free -h
```

### 13.4 Firewall

```bash
ufw allow ssh
ufw allow http
ufw allow https
ufw enable
ufw status verbose
```

> ⚠️ **Só estas três.** Não recrie as regras de FTP da VPS antiga.

### 13.5 Disco adicional (se o plano tiver)

```bash
lsblk -f                        # descobrir o dispositivo
mkfs.ext4 /dev/sdX              # SÓ se for disco novo e vazio
mkdir -p /opt/lojapopcorn
blkid /dev/sdX                  # pegar o UUID
echo 'UUID=<uuid> /opt/lojapopcorn ext4 defaults,nofail,discard 0 0' >> /etc/fstab
mount -a && df -hT
```

> ⚠️ **Não copie o `/dev/disk/by-id/scsi-0DO_Volume_...` do fstab antigo** — é nomenclatura da
> DigitalOcean e não existe na Locaweb. Use UUID. Se o plano for disco único, pule este passo e
> deixe `/opt/lojapopcorn` como pasta comum.

### 13.6 Docker (método 2026 — `apt-key` está deprecado)

```bash
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list

apt update
apt -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl status docker
docker compose version
```

> 💡 O `docker-compose-plugin` do repositório substitui o download manual do binário que estava
> no documento de 2024. `docker compose` (sem hífen) é o comando certo.

### 13.7 Nginx

```bash
apt -y install nginx
systemctl enable --now nginx
ufw allow 'Nginx Full'

nano /etc/nginx/nginx.conf
#   dentro do bloco http { }:
#   server_names_hash_bucket_size 256;

nginx -t && systemctl reload nginx
```

### 13.8 Certbot

```bash
apt -y install certbot python3-certbot-nginx
```

> ⚠️ **Não emita certificado nenhum ainda.** O certbot valida batendo na porta 80 do nome —
> só funciona **depois** que o DNS apontar para a VPS nova. É o passo do cutover (§14).

---

## 14. Migração das aplicações

### 14.1 Basilio (WordPress) — o único com dado vivo relevante

```bash
# ── NA VPS ANTIGA: parar para o dado não mudar durante a cópia
cd /opt/lojapopcorn/site-basilio-imoveis
docker compose down

# ── NA VPS NOVA
mkdir -p /opt/lojapopcorn && cd /opt/lojapopcorn
git clone git@gitlab.com:basilio-imoveis/site-basilio-imoveis.git
```

```bash
# ── Copiar dados (rodar na VPS NOVA, puxando da antiga)
rsync -avzP --numeric-ids root@167.99.225.233:/opt/lojapopcorn/site-basilio-imoveis/{wordpress,mysql,plugins,logo,php} \
      /opt/lojapopcorn/site-basilio-imoveis/
```

> ⚠️ **`--numeric-ids` importa.** O MySQL 5.7 exige que `mysql/` pertença ao UID certo; sem a
> flag o rsync remapeia por nome e o container não sobe.

```bash
# ── NA VPS NOVA: subir
cd /opt/lojapopcorn/site-basilio-imoveis
# (recomendado agora: prefixar 127.0.0.1: nas portas do compose)
docker compose up -d
docker compose logs -f db.basilio     # esperar "ready for connections"
```

**Depois de subir, ajuste as URLs do WordPress** se for testar por outro nome antes do DNS virar
(`siteurl` e `home` na tabela `wp_options`, via phpMyAdmin ou `wp-cli`).

### 14.2 Bolão

```bash
cd /opt/lojapopcorn
git clone git@gitlab.com:maxmat1/bolao.maxmat1.com.br.git
cd bolao.maxmat1.com.br && git checkout master

rsync -avzP root@167.99.225.233:/opt/lojapopcorn/bolao.maxmat1.com.br/{app-build,process,cache-redis} ./
docker compose up -d --build --force-recreate
```

> ⚠️ O build é `FROM node:14` — a imagem ainda existe no Docker Hub, mas é EOL. Se falhar,
> a saída é fixar a versão do npm ou subir o Node — trabalho para outra janela.

### 14.3 Aritmética

```bash
cd /opt/lojapopcorn
git clone git@gitlab.com:e-matematica/landing-pages/aritmetica-instrumental-landing-page.git
cd aritmetica-instrumental-landing-page/app

# Copiar o .env do server por canal seguro (NÃO está no git)
scp root@167.99.225.233:/opt/lojapopcorn/aritmetica-instrumental-landing-page/app/server/.env ./server/.env
chmod 600 server/.env

docker compose up -d --build
```

### 14.4 Corretora de tênis (estático)

```bash
cd /opt && git clone git@gitlab.com:corretora-de-tenis/site-redirecionamento-corretora.git git-corretora-tenis
mkdir -p /opt/site-redirecionamento-corretora
cp /opt/git-corretora-tenis/{index.html,styles.css,script.js} /opt/site-redirecionamento-corretora/
chown -R www-data:www-data /opt/site-redirecionamento-corretora
```

> 💡 Dos 3 domínios do certificado, **só `links.daipipoka.com.br` ainda resolve**. Emita o
> certificado novo **só para os nomes que existem**, ou o certbot falha inteiro por causa dos mortos.

### 14.5 Hermes / Beth

**Siga [`deploy/RESTORE.md`](https://github.com/ChicoFigueiredo/hermes-agent/blob/main/deploy/RESTORE.md).**
Não reescreva o processo aqui — aquele documento é a fonte da verdade e já cobre os detalhes
que quebram (UID/GID, volume do agente, sessão do WhatsApp, deploy key).

### 14.6 Nginx — trazer os sites

```bash
# Copiar os configs (menos os DO-específicos e os obsoletos)
scp root@167.99.225.233:/etc/nginx/sites-available/{api.lojapopcorn.com.br,aritmeticainstrumental.com.br,basilioimoveis.com.br,bolao.maxmat1.com.br,corretora-de-tenis-sites} \
    /etc/nginx/sites-available/

# htpasswd dos painéis (mantém as senhas atuais)
scp root@167.99.225.233:/etc/nginx/{focus,ia-monitor}.htpasswd /etc/nginx/
chown root:www-data /etc/nginx/*.htpasswd && chmod 640 /etc/nginx/*.htpasswd
```

**Antes de habilitar, limpe cada arquivo:** o certbot deixou blocos `listen 443 ssl` apontando
para certificados que ainda não existem na máquina nova. Comente-os, habilite só o `listen 80`,
rode o certbot depois — ele reescreve o bloco 443 sozinho.

```bash
cd /etc/nginx/sites-enabled
for s in api.lojapopcorn.com.br aritmeticainstrumental.com.br basilioimoveis.com.br \
         bolao.maxmat1.com.br corretora-de-tenis-sites; do
  ln -sf /etc/nginx/sites-available/$s .
done
nginx -t && systemctl reload nginx
```

Os configs de `beth`, `focus` e `ia-monitor` **não se copiam à mão** — vêm dos scripts de cada
projeto (§8 e §7.4).

---

## 15. Cutover — ordem de execução

**Dia −2**
- [ ] Baixar TTL de todos os registros para **300s**
- [ ] **Migrar a zona `chicofigueiredo.com.br` para fora da DigitalOcean** (Locaweb ou Cloudflare) — sem isso você não pode encerrar a conta DO
- [ ] Provisionar a VPS Locaweb e rodar §13 inteiro
- [ ] Subir todas as apps com dados de teste e validar por IP / `/etc/hosts` local

**Dia −1**
- [ ] `rsync` completo dos dados (com apps ainda no ar — é o "primeiro passe", vai ficar defasado)
- [ ] Conferir cada site por `/etc/hosts` apontado para o IP novo

**Dia D — janela de manutenção**
1. [ ] Parar os containers na VPS **antiga** (`docker compose down` em cada projeto)
2. [ ] `rsync` **incremental** — segundo passe, agora com o dado congelado (rápido)
3. [ ] Subir os containers na VPS **nova**
4. [ ] **Trocar o DNS** — todos os A/CNAME para o IP novo, incluindo `nova.lojapopcorn.com.br` (é ele que carrega o `ssh.`) e o **curinga** `*.chicofigueiredo.com.br`
5. [ ] Aguardar propagação: `dig +short A basilioimoveis.com.br @1.1.1.1`
6. [ ] **Só então** emitir os certificados:
   ```bash
   certbot --nginx -d basilioimoveis.com.br
   certbot --nginx -d bolao.maxmat1.com.br
   certbot --nginx -d aritmeticainstrumental.com.br -d www.aritmeticainstrumental.com.br \
                   -d aritmeticainstrumental.chicofigueiredo.com.br \
                   -d aritmetica-instrumental.chicofigueiredo.com.br \
                   -d aritmeticainstrumental.chico.mat.br \
                   -d aritmetica-instrumental.chico.mat.br
   certbot --nginx -d api.lojapopcorn.com.br
   certbot --nginx -d links.daipipoka.com.br      # só o que ainda resolve
   ```
7. [ ] Rodar os scripts de túnel de `focus-scrap` e `ia-monitor` (§8) — eles emitem os próprios certificados
8. [ ] Rodar o RESTORE.md da Beth (§7.4), incluindo o re-pareamento do WhatsApp
9. [ ] Rodar o checklist de verificação (§16)

**Dia +1 a +7**
- [ ] Manter o droplet DigitalOcean **ligado mas com nginx parado** — rede de segurança barata
- [ ] Voltar TTL para 3600s
- [ ] Conferir que a primeira renovação automática de certificado passou

**Dia +7**
- [ ] Snapshot final do droplet, arquivar `moddle-sebrae-backup` fora, destruir droplet e volume

> ⚠️ **Não destrua o droplet antes de migrar a zona DNS.** Os nameservers `ns*.digitalocean.com`
> continuam servindo `chicofigueiredo.com.br` — encerrar a conta derruba a resolução de
> beth, focus, ia-monitor e de tudo que depende do curinga.

---

## 16. Checklist de verificação pós-migração

**Servidor**
- [ ] `docker compose ls -a` mostra 4 projetos rodando
- [ ] `docker ps` — 9 containers `Up` (10 menos o `ftp-anon`, que não volta)
- [ ] `nginx -t` sem erro · `systemctl status nginx` ativo
- [ ] `ufw status` — só 22, 80, 443
- [ ] `ss -tulpn | grep LISTEN` — nenhuma porta de app em `0.0.0.0`
- [ ] `systemctl --failed` vazio
- [ ] `free -h` mostra swap ativa
- [ ] `timedatectl` em `America/Sao_Paulo`

**Sites**
- [ ] `https://basilioimoveis.com.br` carrega, admin do WP entra, mídia aparece
- [ ] `https://bolao.maxmat1.com.br` carrega e o Redis responde
- [ ] `https://aritmeticainstrumental.com.br` carrega; os 7 aliases redirecionam para o canônico
- [ ] `https://api.lojapopcorn.com.br` faz proxy para o OpenRouter (testar com chave)
- [ ] `https://links.daipipoka.com.br` serve o HTML estático
- [ ] `https://beth.chicofigueiredo.com.br` pede senha, login entra, resposta chega **token a token**
- [ ] Telegram da Beth responde para o Chico e **ignora** outra conta
- [ ] WhatsApp da Beth responde · `docker compose restart hermes-agent` **não** pede QR de novo
- [ ] `systemctl list-timers hermes-sync` mostra próxima execução
- [ ] `https://focus.chicofigueiredo.com.br` pede senha e mostra o painel (com PC ligado)
- [ ] `https://ia-monitor.chicofigueiredo.com.br` idem
- [ ] `./verificar.sh` passa nos dois projetos de túnel

**TLS**
- [ ] `certbot certificates` lista todos os nomes ativos, todos válidos
- [ ] `certbot renew --dry-run` passa

---

## 17. Comandos de coleta (para refazer este levantamento)

```bash
# Sistema
cat /etc/os-release; uname -a; nproc; free -h; df -hT; lsblk -f; cat /etc/fstab
ip -4 addr show; ip route; timedatectl; swapon --show

# Docker
docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
docker compose ls -a; docker images; docker volume ls; docker network ls; docker system df
docker inspect <c> --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}'

# Nginx / TLS / firewall
ls -la /etc/nginx/sites-enabled/; for f in /etc/nginx/sites-enabled/*; do cat "$(readlink -f $f)"; done
certbot certificates; ufw status verbose; ss -tulpn | grep LISTEN

# SSH e túneis
sshd -T | grep -Ei 'gatewayports|allowtcpforwarding|permitrootlogin|passwordauth'
for u in tunel tunel-ia hermes; do getent passwd $u; cut -d' ' -f1,3- /home/$u/.ssh/authorized_keys; done

# Repos git
find /opt -maxdepth 4 -name .git -type d | while read g; do d=$(dirname "$g");
  echo "$d"; git -C "$d" remote -v | head -1; git -C "$d" log -1 --format='%h %ad %s' --date=short; done

# Cron, timers, serviços
crontab -l; ls /etc/cron.d/; systemctl list-timers --all
ls -la /etc/systemd/system/*.service /etc/systemd/system/*.timer; systemctl --failed

# Uso de disco
du -sh /opt/*; du -sh /opt/lojapopcorn/*; du -sh /var/log
```

---

## Apêndice A — links rápidos

| O quê | Onde |
|---|---|
| Documento original de setup (2024) | [`docs/evernote/…LojaPopCorn NGINX Load Balancer.html`](../evernote/DigitalOcean%20NYC%2030MAI2024%20-LojaPopCorn%20NGINX%20Load%20Balancer/DigitalOcean%20NYC%2030MAI2024%20-LojaPopCorn%20NGINX%20Load%20Balancer.html) |
| Runbook de desastre da Beth | `hermes-agent/deploy/RESTORE.md` |
| Túnel do focus-scrap | `focus-scrap/infra/remote/README.md` |
| Túnel do ia-monitor | `ia-monitor/infra/remote/README.md` |
| Deploy do site de links | `/opt/git-corretora-tenis/DEPLOY.md` |

## Apêndice B — repositórios git no servidor

| Caminho | Remote | Branch | Último commit |
|---|---|---|---|
| `/opt/hermes-agent` | `github.com:ChicoFigueiredo/hermes-agent` | `main` | 09/AGO/2026 |
| `/opt/lojapopcorn/bolao.maxmat1.com.br` | `gitlab.com:maxmat1/bolao.maxmat1.com.br` | `master` | 28/JAN/2026 |
| `/opt/lojapopcorn/aritmetica-instrumental-landing-page` | `gitlab.com:e-matematica/landing-pages/…` | `main` | 29/NOV/2025 |
| `/opt/lojapopcorn/site-basilio-imoveis` | `gitlab.com:basilio-imoveis/site-basilio-imoveis` | `main` | 30/MAI/2024 |
| `/opt/git-corretora-tenis` | `gitlab.com:corretora-de-tenis/site-redirecionamento-corretora` | `main` | 05/JUL/2025 |
| `/opt/lojapopcorn/bolao.maxmat1.com.br-clone` | idem bolão | `master` | 06/ABR/2025 — **não migrar** |
