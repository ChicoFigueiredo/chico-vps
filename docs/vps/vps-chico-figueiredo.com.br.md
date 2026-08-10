# VPS chico-figueiredo.com.br (Locaweb) — servidor novo, pronto para o cutover

> ### ✅ Cutover parcial concluído — 09/AGO/2026, 19h30
>
> A zona **`chicofigueiredo.com.br` já aponta para cá**. Estão em produção nesta VPS:
>
> | Domínio | Estado |
> |---|---|
> | `beth.chicofigueiredo.com.br` | ✅ HTTP 302, TLS OK, Telegram `connected` |
> | `focus.chicofigueiredo.com.br` | ✅ HTTP 401 (basic auth), túnel ativo |
> | `ia-monitor.chicofigueiredo.com.br` | ✅ HTTP 401 (basic auth), túnel ativo |
>
> Também já migrados: `lojapopcorn.com.br`, `api.lojapopcorn.com.br`, `maxmat1.com.br`
> e `bolao.maxmat1.com.br` — o bolão foi verificado servindo conteúdo **byte a byte
> idêntico** ao da VPS antiga, com o Redis populado e o loop de atualização rodando.
>
> **Faltam 3 registros A** (todos no Registro.br), mais dois que valem junto:
>
> | Registro | Por quê |
> |---|---|
> | `aritmeticainstrumental.com.br` | o `www` é CNAME e segue sozinho |
> | `daipipoka.com.br` | o `links.` é CNAME e segue sozinho |
> | `basilioimoveis.com.br` | serve a página de reformulação |
> | `chico.mat.br` | **não é site** — está no certificado da aritmética; se não resolver, a renovação daquele cert falha inteira |
> | `nova.lojapopcorn.com.br` | carrega o `ssh.lojapopcorn.com.br` — **deixe por último**, é o acesso ao droplet |
>
> A VPS antiga continua **ligada e servindo** esses domínios. Nada foi desligado lá além
> da Beth (migrada) e dos túneis (ver §8).
>
> Documento irmão: [vps-lojapopcorn.com.br.md](vps-lojapopcorn.com.br.md) (inventário da VPS antiga)

---

## 1. Ficha técnica — antes e depois

| | **DigitalOcean (antiga)** | **Locaweb (nova)** |
|---|---|---|
| IP | `167.99.225.233` | **`191.252.219.183`** |
| Acesso | `root@ssh.lojapopcorn.com.br` | `root@ssh.chico-figueiredo.com.br` |
| SO | Ubuntu 24.04.4 LTS | Ubuntu 24.04.4 LTS |
| CPU / RAM | 2 vCPU / 3.8 GB | 2 vCPU / 3.8 GB |
| **Swap** | **nenhuma** | **1 GB** ✅ |
| Disco | 24 GB raiz + volume 10 GB | **67 GB, disco único** (25% usado) ✅ |
| Docker | 28.1.1 / Compose 2.35.1 | **29.7.2 / Compose 5.4.0** |
| Nginx | 1.24.0 | 1.24.0 |
| Certbot | 2.x | 2.9.0 |
| fail2ban | não | **sim** ✅ |
| Rotação de log do Docker | não (`/var/log` com 2.7 GB) | **10 MB × 3** ✅ |
| Portas de app expostas | 6 em `0.0.0.0` | **nenhuma** ✅ |

O disco único elimina a dependência do volume `by-id` da DigitalOcean, que era
nomenclatura proprietária e não existiria na Locaweb.

---

## 2. Layout — o que mudou e por quê

Na VPS antiga tudo morava dentro de `/opt/lojapopcorn/`, nome herdado do volume da
DigitalOcean. Como esses sites são de **clientes diferentes** (basilio, maxmat1,
e-matemática, corretora), aninhá-los sob "lojapopcorn" confundia mais do que ajudava —
e o volume nem existe mais.

```
/opt/
├── aritmetica-instrumental/   ← era /opt/lojapopcorn/aritmetica-instrumental-landing-page
├── basilioimoveis/            ← era /opt/lojapopcorn/site-basilio-imoveis
├── bolao-maxmat1/             ← era /opt/lojapopcorn/bolao.maxmat1.com.br
├── hermes-agent/              ← inalterado (o RESTORE.md fixa este caminho)
├── links-corretora/           ← era /opt/git-corretora-tenis
└── _arquivo/                  ← nada aqui roda; só guarda
    ├── moddle-sebrae-backup/  (2.4 GB, dumps de 2024)
    ├── bolao-maxmat1-clone/   (clone morto de ABR/2025)
    ├── mail/                  (docker-mailserver que nunca subiu)
    └── ftp/                   (vsftpd anônimo, quebrado)

/var/www/
├── links-corretora/           ← HTML servido (o repo fica em /opt, a publicação aqui)
└── basilio-manutencao/        ← página "em reformulação"
```

> 💡 **`/opt/hermes-agent` ficou onde estava de propósito.** O `RESTORE.md` e o
> `bootstrap.sh` daquele projeto têm o caminho fixo. Mudar economizaria coerência e
> custaria um runbook de desastre quebrado — troca ruim.

> 💡 **Repositório em `/opt`, publicação em `/var/www`.** O repo do links-corretora tem
> `DEPLOY.md`, `README` e scripts; servir a pasta inteira exporia tudo isso. Só os três
> arquivos do site vão para `/var/www/links-corretora`.

**Todos os arquivos foram copiados, `.env` inclusive**, por rsync direto servidor a
servidor (`-aHAX --numeric-ids`), sem passar por máquina intermediária.

---

## 3. O que está rodando agora na VPS nova

| Container | Estado | Porta | Projeto |
|---|---|---|---|
| `bolao.maxmat1.com.br` | ✅ rodando | `127.0.0.1:5001` | `/opt/bolao-maxmat1` |
| `cache.bolao.maxmat1.com.br` | ✅ rodando | `127.0.0.1:6379` | idem |
| `aritmetica-instrumental-client` | ✅ rodando | `127.0.0.1:11808` | `/opt/aritmetica-instrumental/app` |
| `aritmetica-instrumental-server` | ✅ rodando | `127.0.0.1:3001` | idem |
| `hermes-agent` (Beth) | ⏸️ **parado de propósito** | `127.0.0.1:8642` | `/opt/hermes-agent` |
| `hermes-webui` (Beth) | ⏸️ **parado de propósito** | `127.0.0.1:8787` | idem |
| WordPress do basilio | ❌ **não sobe** | — | ver §7 |
| phpMyAdmin | ❌ **removido** | — | ver §7 |
| `ftp-anon` | ❌ **não migrado** | — | estava quebrado (196 reinícios) |

**Por que a Beth está parada:** o gateway usa Telegram por *long polling*, que aceita
**um consumidor só por bot**. Com as duas Beths de pé, elas se derrubam mutuamente —
foi exatamente o que aconteceu durante esta migração (§8). A Beth de produção continua
sendo a da VPS antiga; a nova sobe no cutover, quando a antiga descer.

Pela mesma razão o `hermes-sync.timer` está **desabilitado** na VPS nova: os dois
servidores empurrando commits para `main` do mesmo repositório se atropelariam.

---

## 4. Segurança — o que mudou

### Nenhuma porta de aplicação exposta

Na VPS antiga, seis portas de container ficavam em `0.0.0.0` — inclusive **Redis** e
**phpMyAdmin**. O UFW não as bloqueava porque o Docker escreve no `iptables` **abaixo**
do UFW: a regra do firewall existe, e o tráfego passa por baixo dela.

Na VPS nova, todo `ports:` foi restrito ao loopback via arquivo de override:

```yaml
# /opt/bolao-maxmat1/docker-compose.override.yaml
services:
  bolao.maxmat1.com.br:
    ports: !override
      - "127.0.0.1:5001:8081"
  cache.bolao.maxmat1.com.br:
    ports: !override
      - "127.0.0.1:6379:6379"
```

> ⚠️ **Por que override e não editar o `docker-compose.yaml`.** O `rebuild-docker.sh` do
> bolão roda `git reset --hard origin/master` — qualquer edição no arquivo versionado
> seria apagada no próximo rebuild, reabrindo as portas em silêncio. O
> `docker-compose.override.yaml` não é versionado e sobrevive.
>
> ⚠️ **A tag `!override` é obrigatória.** Sem ela o Compose **concatena** listas de
> `ports` em vez de substituir — você acabaria com `5001` e `127.0.0.1:5001`, e o
> segundo falharia com porta em uso. `!override` exige Compose ≥ 2.24 (temos 5.4.0).

**Portas públicas hoje: 22, 80 e 443. Nada mais.**

### Outras mudanças

- **UFW** só com SSH + Nginx Full. As regras de FTP da VPS antiga (21, 8080,
  30091-30100, 31000-31009) **não foram recriadas** — existiam só para o `ftp-anon`.
- **fail2ban** instalado e ativo.
- **Rotação de log do Docker** (`/etc/docker/daemon.json`, 10 MB × 3). A VPS antiga
  chegou a 2.7 GB de `/var/log` por não ter isso.
- **Renovação de TLS unificada**: só o `certbot.timer`, com hook único em
  `/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh`. A VPS antiga tinha o timer
  **e** um cron do root fazendo a mesma coisa em paralelo.
- **phpMyAdmin não existe mais** — era a porta de entrada do ataque (§8).

---

## 5. Verificação já feita

Todos os domínios foram testados **forçando o IP novo** (`curl --resolve`), sem depender
de DNS, e comparados com a VPS antiga em produção:

| Domínio | VPS nova | VPS antiga | |
|---|---|---|---|
| `bolao.maxmat1.com.br` | HTTP 200 | HTTP 200 | ✅ conteúdo byte a byte idêntico¹ |
| `aritmeticainstrumental.com.br` | HTTP 200 | HTTP 200 | ✅ hash idêntico |
| `www.aritmeticainstrumental.com.br` | HTTP 301 | HTTP 301 | ✅ redirect canônico |
| `api.lojapopcorn.com.br` | HTTP 200² | HTTP 200² | ✅ 655.413 bytes idênticos do OpenRouter |
| `links.daipipoka.com.br` | HTTP 200 | HTTP 200 | ✅ hash idêntico |
| `beth.chicofigueiredo.com.br` | HTTP 302 | HTTP 302 | ✅ redirect de login |
| `focus.chicofigueiredo.com.br` | HTTP 401 | HTTP 401 | ✅ basic auth + túnel ativo |
| `ia-monitor.chicofigueiredo.com.br` | HTTP 401 | HTTP 401 | ✅ basic auth + túnel ativo |
| `basilioimoveis.com.br` | HTTP 200 | HTTP 500 | ⚠️ proposital — §7 |

¹ A única diferença eram 3 segundos no carimbo "atualizado em" — o app renderiza a hora
da requisição. Ignorando o carimbo, o SHA-256 bate.
² Medido em `/api/v1/models`. Na raiz `/` os dois devolvem 502 — comportamento idêntico,
é o `rewrite` da raiz, não uma falha.

**TLS:** os 8 certificados foram copiados de `/etc/letsencrypt`. Todos verificam com
`ssl_verify_result=0` no IP novo. O da Beth foi instalado com `certbot install`, que
aplica um certificado existente **sem revalidar DNS** — por isso já há TLS válido antes
do cutover.

**Teste de reboot:** a VPS nova foi reiniciada. Voltaram sozinhos os 6 containers, o
nginx, o UFW, o fail2ban e os dois túneis (reconectados pela máquina de casa). Zero
serviços em estado `failed`.

**Túneis:** subiram **em paralelo** para os dois servidores durante a transição — quatro
sessões, duas para cada lado — o que fez o cutover não ter janela de queda. Não foi
preciso gerar chave nova: o `authorized_keys` foi copiado com a mesma restrição
`permitlisten`.

Com o `chicofigueiredo.com.br` já na Locaweb, as pernas para a VPS antiga foram
**desligadas** em 09/AGO/2026:

```bash
systemctl --user disable --now focus-tunel.service ia-monitor-tunel.service
```

Confirmado no droplet: nenhuma ponta em 17788/21985 e nenhuma sessão sshd dos usuários
`tunel`/`tunel-ia`. Os painéis seguem em 401 (desafio de senha) pela Locaweb.

> 💡 **O controle dos túneis é na máquina de casa, não no servidor** — é ela que disca.
> "Desligar o túnel no droplet" se faz parando o serviço systemd daqui; no servidor não há
> o que desligar, ele só recebe.

Falta atualizar `TUNEL_HOST`/`DROPLET` nos `config.sh` dos dois projetos, para que uma
reinstalação futura aponte para o servidor certo.

**Chave git do root:** copiada do droplet em 09/AGO/2026
(`SHA256:pQkyjJ+0YZ3TLO6zNc4Xki8nJeql9gquIO7zEIym4XQ`), junto com o `.gitconfig` e seus
aliases. Os quatro repositórios GitLab fazem `fetch` normalmente. O root **não** tem
acesso ao GitHub — nem tinha no droplet; o único repo lá (`hermes-agent`) usa a deploy
key própria do usuário `hermes`.

---

## 6. Cutover — o que falta

### Antes (pode ser hoje)

- [x] ~~Migrar a zona `chicofigueiredo.com.br` para fora da DigitalOcean.~~
      **Feito em 09/AGO/2026** — a zona agora está na Locaweb
      (`ns1/ns2/ns3.locaweb.com.br`). Ver §12 para as pegadinhas que apareceram.
- [ ] Baixar o TTL dos registros para **300s** (~2 dias de antecedência).

### No dia — ordem importa

```bash
# 1. Parar a Beth ANTIGA (libera o bot do Telegram)
ssh root@ssh.lojapopcorn.com.br \
  'docker compose -f /opt/hermes-agent/deploy/compose.yml stop'

# 2. Subir a Beth NOVA e religar o sync
ssh root@ssh.chico-figueiredo.com.br \
  'docker compose -f /opt/hermes-agent/deploy/compose.yml start && \
   systemctl enable --now hermes-sync.timer'

# 3. Virar o DNS — todos para 191.252.219.183
```

Registros a mudar (ver §3 do documento da VPS antiga para a lista completa):

| Registro | Observação |
|---|---|
| `lojapopcorn.com.br` (A) | |
| `nova.lojapopcorn.com.br` (A) | **é ele que carrega o `ssh.`**, que é CNAME |
| `basilioimoveis.com.br` (A) | |
| `aritmeticainstrumental.com.br` (A) | |
| `chicofigueiredo.com.br` (A) **+ curinga `*`** | cobre beth, focus, ia-monitor |
| `chico.mat.br` (A) | alias da aritmética |
| `maxmat1.com.br` (A) | `bolao.` é CNAME para ele |
| `daipipoka.com.br` (A) | `links.` é CNAME para ele |

```bash
# 4. Conferir propagação
dig +short A bolao.maxmat1.com.br @1.1.1.1     # deve devolver 191.252.219.183

# 5. Conferir a renovação de TLS (só funciona DEPOIS do DNS apontar para cá)
ssh root@ssh.chico-figueiredo.com.br 'certbot renew --dry-run'
```

> ⚠️ O `certbot renew --dry-run` **falha antes do cutover** e isso é esperado: o
> Let's Encrypt valida batendo na porta 80 do nome, que ainda chega na VPS antiga.
> É a única verificação que não pôde ser feita antecipadamente.

### Depois de estabilizar

```bash
# Túnel: desligar as pernas que ainda vão para a VPS antiga (na máquina de casa)
systemctl --user disable --now focus-tunel.service ia-monitor-tunel.service

# Atualizar o config.sh dos dois projetos para o servidor novo
#   focus-scrap/infra/remote/config.sh  →  DROPLET / TUNEL_HOST
#   ia-monitor/infra/remote/config.sh   →  DROPLET / TUNEL_HOST

# Remover a chave de migração da VPS antiga (não é mais necessária)
ssh root@ssh.lojapopcorn.com.br \
  "sed -i '/migracao-locaweb@chico-figueiredo/d' /root/.ssh/authorized_keys"
```

- [ ] Voltar o TTL para 3600s
- [ ] Manter a VPS antiga ligada com o **nginx parado** por ~7 dias (rede de segurança)
- [ ] Só então: snapshot final e destruição do droplet

### Delta de dados no cutover

**Não há.** Nenhuma das aplicações migradas guarda dado que mude sozinho:

- **bolão** — busca resultados de API externa a cada requisição; o Redis é cache puro
- **aritmética** — sem estado local (usa Supabase)
- **links** — HTML estático
- **Beth** — o estado vive no git e o repo está no mesmo commit (`f2e7224`) nos dois
- **basilio** — não sobe

Se ficar muitos dias entre hoje e o cutover, vale um `git pull` nos repos antes de subir.

---

## 7. basilioimoveis.com.br — decisão registrada

O site **não sobe na VPS nova**, por decisão sua: será refeito do zero, já que o
conteúdo antigo se perdeu (§8) e o site não estava em uso.

**O que foi preservado** em `/opt/basilioimoveis/` (1.2 GB): tema Houzez, plugins,
`wp-content/uploads` com 158 MB e 1.202 arquivos, e o `docker-compose.yaml` original.
Nada foi descartado.

**O que responde hoje:** `https://basilioimoveis.com.br` serve uma página estática de
"em reformulação", com o certificado válido — em vez de erro de TLS ou da página padrão
do nginx. Arquivos em `/var/www/basilio-manutencao/`, vhost em
`/etc/nginx/sites-available/basilioimoveis.com.br`.

Quando o site novo existir, é trocar o `root` do vhost por um `proxy_pass`.

---

## 8. Incidente — ransomware no banco do basilio (04/JUL/2026)

Descoberto durante esta migração, ao tentar copiar o banco.

**O que aconteceu.** Em **04/JUL/2026 às 23:30**, o banco `wp_basilio` foi apagado e
substituído por uma única tabela `readme_to_recover` com pedido de resgate de
**0,009 BTC**, prazo de 72h e código `YS298`. O site responde HTTP 500 desde então —
cinco semanas antes desta migração começar.

**Vetor.** O `phpMyAdmin` estava publicado em `0.0.0.0:8095` **com `PMA_USER` e
`PMA_PASSWORD` definidos no compose** — ou seja, quem abrisse `http://167.99.225.233:8095`
caía **já autenticado** no banco, sem senha nenhuma. É um alvo varrido por bots.

**Alcance — verificado, não presumido.**

| Verificação | Resultado |
|---|---|
| PHP modificado após 04/JUL em `wordpress/` | nenhum |
| Webshell em `wp-content/uploads/` | nenhum (só o `index.php` padrão do Redux) |
| `_____php.php` montado pelo compose | arquivo seu, 28 bytes, `phpinfo()` — não é webshell |
| Redis do bolão | intacto, exige autenticação |
| Demais sites | todos saudáveis |
| Backup do banco no servidor | **nenhum** — sem plugin de backup instalado |

**Conclusão:** o dano ficou contido ao banco do basilio.

**Não pague.** Nesse tipo de ataque em massa o script apaga e deixa o bilhete; os dados
quase nunca são realmente copiados. O valor baixo e o "DBCODE" genérico são a assinatura
da campanha automatizada.

**O que muda daqui para frente:** na VPS nova o phpMyAdmin não existe, e nenhuma porta de
banco ou de aplicação é alcançável de fora. O mesmo ataque não teria por onde entrar.

> 📌 **A lição que sobra: não havia backup.** Nenhum dos sites tem rotina de backup hoje.
> Vale montar uma antes de considerar a migração encerrada — ver §10.

---

## 9. Erro cometido durante a migração (e como foi corrigido)

Ao subir a Beth nova para testar, ela se conectou ao **mesmo bot do Telegram** da Beth
de produção. O Telegram aceita um consumidor por bot: as duas entraram em conflito de
`getUpdates` e a de produção **desistiu após 5 tentativas**, ficando sem Telegram.

**Corrigido:** a Beth nova foi parada, o gateway antigo reiniciado, e a produção voltou
com **zero conflitos**. Confirmado por `hermes gateway status` (gateway rodando, PID 150).

O aviso de "WhatsApp não pareado" que aparece nos logs **é anterior e não tem relação**:
não existe sessão de WhatsApp em nenhuma das duas VPS — nunca foi pareado ali.

É a razão pela qual a Beth nova fica parada até o cutover (§3), e por que o passo 1 do
cutover é parar a antiga **antes** de subir a nova.

---

## 9b. Dois bugs pré-existentes no `hermes-sync`, corrigidos em 09/AGO/2026

Encontrados ao verificar a Beth na VPS nova. **Não foram introduzidos pela migração** — o
droplet tinha os mesmos 16 erros no journal, e os units no servidor eram idênticos aos
versionados em `deploy/systemd/` do repositório `hermes-agent`.

### 1. `Environment=` sem aspas quebrava o `GIT_SSH_COMMAND`

```ini
# errado — o systemd parte em tokens e GIT_SSH_COMMAND vira apenas "ssh"
Environment=GIT_SSH_COMMAND=ssh -i /home/hermes/.ssh/id_ed25519 -o IdentitiesOnly=yes ...

# certo
Environment="GIT_SSH_COMMAND=ssh -i /home/hermes/.ssh/id_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes"
```

Sintoma no journal: `Invalid environment assignment, ignoring: -i`, `... -o`, etc.

Funcionava por acaso: `id_ed25519` é um nome de chave padrão, então o `ssh` a encontrava
sozinho. O que se perdia eram o `IdentitiesOnly=yes` e o `StrictHostKeyChecking=yes` —
justamente as duas garantias de que o sync usa **aquela** chave e não aceita host novo.

### 2. `Persistent=true` era ignorado, e o timer parou de disparar

```ini
# antes — Persistent= NÃO tem efeito com temporizador monotônico
OnBootSec=10min
OnUnitActiveSec=30min
Persistent=true

# agora
OnCalendar=*:0/30
Persistent=true
RandomizedDelaySec=60
```

Dois problemas em um:

- **`Persistent=` só vale para `OnCalendar`.** Com `OnBootSec`/`OnUnitActiveSec` o systemd
  o ignora em silêncio — ou seja, a promessa de "roda assim que o servidor voltar" nunca
  existiu.
- Com temporizador monotônico, se o timer é ativado **depois** do instante de `OnBootSec`
  já ter passado, ele entra em `active (elapsed)` com `Trigger: n/a` e **para de disparar
  sem avisar**. Foi o que aconteceu: a Beth ficou 3h sem sincronizar, com o timer
  aparecendo como `enabled` e `active`.

Depois da correção: `Trigger: Sun 2026-08-09 22:30:04` e o sync rodou (`sync: enviado.`,
commit `44fedc1`).

> 📌 A correção foi aplicada **também** em `/opt/hermes-agent/deploy/systemd/`, então
> aparece como modificação no repositório `hermes-agent`. Vale commitar lá — o `sync.sh`
> só faz `git add -- home/`, então não commita sozinho.

---

## 9c. "GATEWAY ENDPOINT NOT REACHABLE" na webui da Beth — resolvido

**Sintoma:** em *Scheduled Jobs*, aviso vermelho "Gateway endpoint not reachable", e os
jobs agendados nunca disparavam. O `HERMES_API_URL=http://hermes-agent:8642` estava
correto e o DNS da rede docker resolvia — mas **nada escutava na 8642**, nem de dentro do
próprio container do agente.

**Causa: `home/.env` não tinha `API_SERVER_KEY`.** O `gateway/config.py` do agente só
carrega a plataforma `api_server` quando existe uma chave utilizável (mínimo 16
caracteres, via `has_usable_secret`). Sem ela o gateway sobe normal — Telegram conecta,
tudo parece bem — e simplesmente não abre porta nenhuma.

O que confundia o diagnóstico: o `gateway_state.json` mostrava `api_server: connected`.
Era estado **velho**, copiado do droplet no rsync, com `updated_at` de antes da migração.
A instância nova nunca o atualizou.

### A segunda metade, que faria a primeira parecer não ter funcionado

```python
# gateway/platforms/api_server.py
DEFAULT_HOST = "127.0.0.1"
```

Com a chave definida mas o host no padrão, o servidor sobe ligado ao **loopback do
container do agente** — e a `hermes-webui`, que vive em *outro* container, continua sem
alcançar. É preciso `API_SERVER_HOST=0.0.0.0` também.

### A correção

Duas linhas em `/opt/hermes-agent/home/.env`:

```bash
API_SERVER_KEY=<mesmo valor de HERMES_GATEWAY_API_KEY em deploy/.env>
API_SERVER_HOST=0.0.0.0
```

`API_SERVER_PORT` não precisa: o padrão já é 8642. `API_SERVER_ENABLED` também não — o
comentário no próprio código diz que a chave é o que habilita ("API_SERVER_ENABLED alone
would load an…" sem chave utilizável não basta).

Depois de `docker compose restart hermes-agent`:

```
hermes-agent:8642/health           HTTP 200   (da webui)
hermes-agent:8642/health/detailed  HTTP 401 sem chave, 200 com — correto, é autenticado
plataformas: telegram connected · api_server connected · whatsapp fatal (não pareado)
cron: Loterias Monitor        Last run ok, completed
      Loterias Relatório 8h   Last run ok, completed
```

> 📌 **`deploy/hermes-env.example` já documentava as duas** — o `home/.env` real é que
> tinha sido criado sem elas. Como `home/.env` é segredo e fica fora do git, uma
> recuperação de desastre repetiria o problema. Vale a pena o `RESTORE.md` citar
> `API_SERVER_KEY` na lista de segredos a repor, ao lado do `OPENROUTER_API_KEY`.

> ⚠️ **Aviso legítimo que o agente passou a emitir:** com `0.0.0.0` e `terminal.backend:
> local`, quem alcançar a 8642 **com a chave** dispara trabalho como usuário do host. Aqui
> o alcance é só a rede docker `hermes-net` (onde só a webui vive) e o loopback do host —
> a porta é publicada como `127.0.0.1:8642`, nunca exposta. Para apertar mais: remover o
> `ports:` do `hermes-agent` no compose (a webui fala pela rede docker, não precisa da
> porta no host) ou migrar o terminal para `backend: docker`.

---

## 10. Pendências recomendadas (fora do escopo desta migração)

1. **Rotina de backup** — nenhum site tem. Foi o que transformou o incidente do basilio
   em perda total. Um `mysqldump` + `tar` do `wp-content` num cron diário, guardado fora
   do servidor, teria resolvido.
2. **`mysql:5.7`** (basilio) está sem suporte desde OUT/2023 — se o site for refeito,
   nasça em 8.0.
3. **`node:14`** (bolão) morreu em ABR/2023. Constrói e roda, mas é dívida.
4. **Sessão do WhatsApp da Beth** nunca foi pareada — se quiser WhatsApp, é o passo 5 do
   `RESTORE.md`.
5. **`links.corretora-de-tenis.com.br` e `links.corretoradetenis.com.br`** não resolvem
   mais. O certificado ainda os cobre; na próxima renovação, emita só para
   `links.daipipoka.com.br` ou a renovação falha por causa dos nomes mortos.

---

## 11. Comandos úteis

```bash
# Acesso
ssh root@ssh.chico-figueiredo.com.br

# Estado geral
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
systemctl --failed
ufw status verbose
ss -tulpn | grep LISTEN          # nenhuma app deve estar em 0.0.0.0

# Stacks
cd /opt/bolao-maxmat1            && docker compose up -d --build
cd /opt/aritmetica-instrumental/app && docker compose up -d --build
docker compose -f /opt/hermes-agent/deploy/compose.yml up -d

# Conferir que o override de portas está valendo
cd /opt/bolao-maxmat1 && docker compose config | grep -A3 ports:

# TLS
certbot certificates
certbot renew --dry-run          # só funciona depois do DNS apontar para cá

# Testar um domínio sem depender de DNS
curl -s -o /dev/null --resolve 'bolao.maxmat1.com.br:443:191.252.219.183' \
     -w 'HTTP %{http_code} TLS=%{ssl_verify_result}\n' https://bolao.maxmat1.com.br/

# Túneis (na máquina de casa)
systemctl --user status focus-tunel-novo ia-monitor-tunel-novo
```

---

## 12. DNS na Locaweb — duas limitações que mudam a rotina

Descobertas ao migrar a zona `chicofigueiredo.com.br` da DigitalOcean para a Locaweb.

### Não aceita registro curinga

O painel da Locaweb **rejeita o `*`** no campo *Entrada*. Não existe caractere
alternativo — o curinga é o rótulo literal `*` pela RFC 1034, em qualquer provedor. É
bloqueio do painel, aplicado depois de uma atualização deles, e não está documentado.

Na DigitalOcean havia `*.chicofigueiredo.com.br`, e era ele que fazia um painel novo
"só precisar do nginx". Aqui, cada nome precisa de entrada própria. As criadas foram:

| Entrada | Tipo | Aponta para |
|---|---|---|
| `.` (apex) | A | `191.252.219.183` |
| `beth` · `focus` · `ia-monitor` | CNAME | `chicofigueiredo.com.br` |
| `aritmeticainstrumental` · `aritmetica-instrumental` | CNAME | `chicofigueiredo.com.br` |

> 💡 CNAME para o apex em vez de A repetido é melhor do que parece: se o IP mudar de novo,
> só o apex precisa ser editado.

> ⚠️ **Os dois nomes da aritmética não são opcionais.** Estão dentro do certificado
> `aritmeticainstrumental.com.br`, e o Let's Encrypt valida **todos** os nomes de um
> certificado — um que não resolva derruba a renovação inteira.

### Não tem API nem CLI de DNS

O portal de desenvolvedores da Locaweb expõe três APIs — **Servidores** (dedicados,
Cloud Server Pro e VPS, 52 endpoints, `https://api-servidores.locaweb.com.br/v1`),
**Email Marketing** e **SMTP**. **Nenhuma de DNS.** Não há CLI oficial.

### O que isso custa

Sem curinga e sem API, todo subdomínio novo vira **duas ações manuais**: entrada no
painel web + vhost no servidor. Antes era só o vhost.

**Alternativa, se incomodar:** manter o domínio registrado na Locaweb e apontar os NS
para um provedor de DNS com curinga e API — o Cloudflare DNS é gratuito e resolve os
dois. Não é urgente; o que está no ar funciona.

### Pegadinha do cutover: cache negativo de 60 minutos

O SOA da Locaweb tem `minimum = 3600`. Quando a zona foi delegada ainda vazia, os
resolvedores públicos cachearam "este nome não existe" **por até uma hora** — e
continuaram devolvendo vazio mesmo depois dos registros entrarem.

Não há como forçar a limpeza de resolvedor público; é esperar. Localmente resolve na hora:

```powershell
ipconfig /flushdns                      # Windows (admin)
# Chrome mantém cache próprio:
#   chrome://net-internals/#dns      → Clear host cache
#   chrome://net-internals/#sockets  → Flush socket pools
```
```bash
sudo resolvectl flush-caches            # WSL
```

> 💡 **Lição para o resto do cutover:** crie os registros na zona nova **antes** de mudar
> a delegação de NS. Delegar para uma zona vazia gera uma hora de cache negativo de graça.

---

## Apêndice — usuários de serviço

Os UIDs mudaram porque `1000` já é do usuário `cloud` da Locaweb, e `999` é o UID interno
que os containers de MySQL e Redis usam — deixá-lo livre evita que dados de bind mount
apareçam como propriedade de um usuário do host.

| Usuário | UID antigo | UID novo | Para quê |
|---|---|---|---|
| `tunel` | 1000 | **1001** | túnel do focus-scrap (porta 17788) |
| `tunel-ia` | 1001 | **1002** | túnel do ia-monitor (porta 21985) |
| `hermes` | 1002 | **1003** | dono de `/opt/hermes-agent` |

> ⚠️ O `deploy/.env` da Beth teve `UID`/`GID` atualizados de 1002 para 1003 à mão. O
> `bootstrap.sh` não faz isso quando o `.env` já existe — e com o UID errado a webui
> entra em laço de reinício por não conseguir escrever em `home/`.
