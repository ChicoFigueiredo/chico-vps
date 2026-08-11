# chico-vps

Backup versionado da configuração das minhas VPS: o que roda, onde, por quê, e como
reconstruir se a máquina sumir.

Guarda a **forma** da configuração — compose, scripts, units do systemd, vhosts do nginx.
Segredo nenhum entra aqui: senhas e chaves vivem no BitWarden e nos `.env` de modo 600 nos
servidores, e o [`.gitignore`](.gitignore) barra `*.env`, `credenciais/`, `*.dump` e
`dados/`.

---

## Estado atual — 10/AGO/2026

Migração da **DigitalOcean → Locaweb** feita em 09/AGO/2026. Cutover parcial: 6 domínios
já servidos pela VPS nova, 3 ainda na antiga.

| | DigitalOcean (antiga) | **Locaweb (nova)** |
|---|---|---|
| IP | `167.99.225.233` | **`191.252.219.183`** |
| SSH | `root@ssh.lojapopcorn.com.br` | `root@ssh.chico-figueiredo.com.br` |
| Recursos | 2 vCPU / 3.8 GB / 24 GB + volume 10 GB | 2 vCPU / 3.8 GB / **67 GB** |
| Em uso | — | 1.3 GB de RAM · 17 GB de disco (27%) |
| Estado | ligada, servindo 3 domínios | **produção** |

### Onde cada domínio está

| Domínio | Servidor | O que é |
|---|---|---|
| `beth.chicofigueiredo.com.br` | ✅ nova | agente Hermes ("Beth") — Telegram + webui |
| `focus.chicofigueiredo.com.br` | ✅ nova | painel do focus-scrap, **roda em casa** via túnel SSH |
| `ia-monitor.chicofigueiredo.com.br` | ✅ nova | painel do ia-monitor, **roda em casa** via túnel SSH |
| `bolao.maxmat1.com.br` | ✅ nova | bolão do Brasileirão (Node + Redis) |
| `api.lojapopcorn.com.br` | ✅ nova | proxy reverso para o OpenRouter |
| `lojapopcorn.com.br` | ✅ nova | — |
| `aritmeticainstrumental.com.br` | ⏳ antiga | landing page (React + Node) |
| `links.daipipoka.com.br` | ⏳ antiga | site estático de links |
| `basilioimoveis.com.br` | ⏳ antiga | ⚠️ fora do ar desde 04/JUL — ver incidente |

### O que falta para desligar o droplet

3 registros **A** no Registro.br, de `167.99.225.233` para `191.252.219.183`:

```
aritmeticainstrumental.com.br     (o www é CNAME e segue sozinho)
daipipoka.com.br                  (o links. é CNAME e segue sozinho)
basilioimoveis.com.br
```

Mais dois que valem junto:

- **`chico.mat.br`** — não é site, mas está dentro do certificado da aritmética. Se não
  resolver, a renovação daquele certificado falha **inteira**.
- **`nova.lojapopcorn.com.br`** — carrega o `ssh.lojapopcorn.com.br`. **Deixe por último**:
  depois de virar, o acesso ao droplet é só pelo IP.

Os três já respondem certo na Locaweb, com certificado válido. Detalhes e checklist
completo em [vps-chico-figueiredo.com.br.md](docs/vps/vps-chico-figueiredo.com.br.md#6-cutover--o-que-falta).

---

## Documentação

| Documento | O que cobre |
|---|---|
| [**vps-chico-figueiredo.com.br.md**](docs/vps/vps-chico-figueiredo.com.br.md) | **Operacional.** A VPS nova: layout, serviços, verificações feitas, runbook de cutover, limitações do DNS da Locaweb |
| [**banco-postgresql.md**](docs/vps/banco-postgresql.md) | PostgreSQL compartilhado — criar bancos, conectar, backup, restore |
| [**cache-redis.md**](docs/vps/cache-redis.md) | Redis compartilhado — ACL por projeto, política de memória, backup |
| [**s3-seaweedfs.md**](docs/vps/s3-seaweedfs.md) | Objetos compartilhados — bucket por projeto, painel pelo túnel, backup com lixeira |
| [**seguranca.md**](docs/vps/seguranca.md) | Camadas de proteção do nginx, fail2ban, e o que ainda dá para fazer |
| [**vps-lojapopcorn.com.br.md**](docs/vps/vps-lojapopcorn.com.br.md) | **Histórico.** Inventário completo do droplet antes da migração |
| [docs/evernote/](docs/evernote/) | O passo a passo original de 30/MAI/2024 que criou o droplet |

---

## Infraestrutura compartilhada

Três serviços que qualquer projeto hospedado na VPS pode usar. Todos escutam **só em
`127.0.0.1`** e são alcançados pelos containers por rede docker externa.

### `banco` — PostgreSQL 17 + pgvector

```bash
novo-banco meuprojeto                  # database + role isolados
novo-banco meuprojeto vector pg_trgm   # já com extensões
banco meuprojeto                       # abre o psql
```

~66 MB de RAM. Cada projeto ganha database e role próprios, com `CONNECT` revogado do
`PUBLIC` — testado: um projeto não alcança o banco do outro. Backup diário às 03:20,
retenção 14 dias, **restore verificado**.

> Extensões exigem superusuário (`pgvector` não é *trusted extension*) — por isso o
> `novo-banco` as recebe como argumento.

### `cache` — Redis 8

```bash
novo-cache meuprojeto     # usuário ACL restrito a chaves 'meuprojeto:*'
cache DBSIZE              # redis-cli como admin
```

~5 MB de RAM, teto de 256 MB. Isolamento por **ACL + prefixo de chave** — os 16 databases
numerados do Redis não isolam nada, qualquer cliente autenticado dá `SELECT` em todos.

Política de memória `volatile-lru`: só despeja chave **com TTL**, ou seja, o que o app
marcou como descartável. Fila e sessão sem TTL ficam intactas.

> Escuta na **6380** do host, não 6379 — a 6379 é do Redis do bolão, que segue rodando em
> paralelo até o bolão ser remodelado.

### `s3` — armazenamento de objetos (SeaweedFS 4.41)

```bash
bun run s3:novo meuprojeto     # bucket + credencial isolados
bun run s3:tunel               # abre o painel em http://127.0.0.1:9001
bun run s3:status              # buckets, usuários, disco, timer
```

~65 MB de RAM no servidor e ~25 MB no painel. Guarda arquivo de aplicação — upload de
usuário, anexo, imagem, PDF — com a API da AWS S3: no código é
`@aws-sdk/client-s3` normal, só com o endpoint apontado para cá.

Cada projeto ganha bucket e credencial próprios, com a política presa ao nome do
bucket. Testado: um projeto não lista, não lê e não grava no bucket do outro — e o
`ListAllMyBuckets` é filtrado, então nem descobre que os outros existem.

**O painel só existe pelo túnel.** As portas 9000 e 9001 não são alcançáveis da
internet — verificado de fora, com a 443 respondendo no mesmo teste.

> Não é MinIO: o repositório foi **arquivado em ABR/2026** e a administração já tinha
> saído do console community em MAI/2025. Seria adotar um daemon sem caminho de patch
> para guardar os arquivos de todos os projetos.

Arquivos reais em [`vps/banco/`](vps/banco/), [`vps/cache/`](vps/cache/),
[`vps/s3/`](vps/s3/) e [`vps/bin/`](vps/bin/).

---

## Segurança

Endurecimento aplicado em 09/AGO/2026, depois do incidente abaixo.

- **Nenhuma porta de aplicação em `0.0.0.0`** — só 22, 80 e 443 são públicas. Na VPS antiga
  eram seis, incluindo Redis e phpMyAdmin.
- **Basic auth do nginx** antes da webui da Beth, somado ao login que ela já tem.
- **Rate limit** de 20 req/s por IP.
- **fail2ban** com 4 jails: SSH, senha errada, excesso de requisições e varredura de
  caminhos de CMS.
- **`hermes-agent` sem porta publicada** — a webui o alcança pela rede docker.

> ⚠️ O UFW **não** bloqueia porta publicada por container: o Docker escreve no `iptables`
> abaixo dele. Por isso todo `ports:` de compose leva o prefixo `127.0.0.1:`, via
> `docker-compose.override.yaml` com a tag `!override` — que sobrevive ao
> `git reset --hard` dos scripts de rebuild.

### Incidente: ransomware no banco do basilio (04/JUL/2026)

Descoberto durante a migração. O banco `wp_basilio` foi apagado e substituído por uma
tabela `readme_to_recover` pedindo 0,009 BTC. O site respondia 500 havia cinco semanas.

**Vetor:** phpMyAdmin publicado em `0.0.0.0:8095` **com usuário e senha no compose** —
quem abrisse o IP na porta caía já autenticado no banco.

**Alcance verificado:** nenhum PHP alterado, nenhum webshell, demais sites intactos. O
dano ficou no banco do basilio. Os arquivos (tema, plugins, 158 MB de uploads) foram
preservados; o site será refeito do zero.

**O que faltou:** backup. Não havia nenhum — foi isso que transformou o incidente em perda
total. Hoje os três serviços têm backup diário. O do `s3` já tem saída para fora da
máquina (`bun run s3:puxar`) e guarda numa lixeira datada o que for apagado ou
sobrescrito — apagar por engano, ou um ransomware apagar por você, não propaga para o
backup no mesmo instante. O `banco` e o `cache` seguem gravando **no mesmo disco**:
protege contra erro humano e corrupção, não contra perder a máquina.

Na VPS nova o phpMyAdmin não existe.

---

## Projetos que rodam em casa, não na VPS

`focus-scrap` e `ia-monitor` rodam na máquina de casa. A VPS é só o **cano com TLS e senha
na ponta**: um túnel SSH reverso que o próprio PC disca, saindo pela porta 22 — sem porta
aberta no roteador, sem IP fixo, funcionando atrás do NAT da operadora.

```
tablet ──HTTPS──▶ nginx na VPS ──▶ 127.0.0.1:PORTA (ponta do túnel)
                  (TLS + senha)              ▲
                                             │ túnel SSH reverso
                              PC de casa ────┘
```

| | focus-scrap | ia-monitor |
|---|---|---|
| Usuário do túnel | `tunel` | `tunel-ia` |
| Porta (fixa dos dois lados) | 17788 | 21985 |

**502 com o PC desligado é o esperado**, não é falha da VPS.

Os dois têm scripts idempotentes em `infra/remote/` que refazem tudo — chave, usuário sem
shell, nginx, certbot. As chaves são restritas com `restrict,port-forwarding,permitlisten`:
sem shell, sem agent forwarding, e sem poder escutar em outra porta.

> **Estes devem continuar em SQLite.** O banco local é o que faz o painel funcionar com a
> internet oscilando. O Postgres compartilhado é para projetos hospedados *na* VPS.

---

## Estrutura do repositório

```
docs/
├── vps/                     documentação operacional e histórica
└── evernote/                o passo a passo original de 2024
scripts/                     operação a partir daqui — 'bun run s3:*'
vps/
├── banco/                   compose, scripts e units do PostgreSQL
├── cache/                   compose, conf, scripts e units do Redis
├── s3/                      compose, scripts e units do SeaweedFS
├── bin/                     atalhos 'banco', 'cache' e 's3' (/usr/local/bin)
└── seguranca/               vhost com auth, rate limit, jails do fail2ban
```

Os arquivos em `vps/` são cópia fiel do que roda no servidor — servem para recriar do
zero. Cada documento tem uma seção "Recriar do zero" no fim.

---

## Armadilhas que já custaram tempo

Registradas porque voltariam a morder. Detalhe completo em cada documento.

| Armadilha | Sintoma |
|---|---|
| **IP banido pelo fail2ban** | página não carrega, **sem erro** — o pacote é descartado. Parece container caído. Cheque `fail2ban-client status nginx-http-auth` antes de investigar Docker |
| **Delegar NS para zona vazia** | os resolvedores cacheiam "não existe" por até 1 h. Crie os registros **antes** de mudar os nameservers |
| **Locaweb não aceita `*` no DNS** | curinga é bloqueado no painel, e não há caractere alternativo. Cada subdomínio precisa de registro próprio |
| **`Persistent=` sem `OnCalendar`** | é ignorado em silêncio; o timer entra em `active (elapsed)` e para de disparar parecendo saudável |
| **`Environment=` com espaços sem aspas** | o systemd parte em tokens e a variável chega truncada |
| **fail2ban com `backend = systemd`** | o nginx grava em arquivo; a jail lê um journal vazio e conta zero para sempre |
| **`API_SERVER_HOST` padrão é `127.0.0.1`** | dentro do container — outro container não alcança, mesmo com a chave certa |
| **`appendonly yes` ignora o `dump.rdb`** | restaurar RDB sem tirar o `appendonlydir` devolve os dados antigos |
| **`ports:` em override concatena** | sem a tag `!override` você fica com as duas portas, e a segunda falha |
| **`docker exec -i` consome stdin** | dentro de script, engole as linhas seguintes — o script para sem erro |
| **Gateway S3 nasce sem senha** | sem identidade configurada o SeaweedFS aceita tudo **anonimamente** — `curl` sem credencial cria bucket e grava. O `bootstrap.sh` é o que fecha |
| **SeaweedFS só corrige `/data`** | o entrypoint acerta a dona da pasta montada, mas conhece um caminho só. Montado noutro lugar, o erro é "please verify /X is writable" e não sugere a causa |
| **`pipefail` + `/dev/urandom` + `head`** | o `head` fecha o cano, o `tr` morre de SIGPIPE e o script encerra **depois** de atribuir a variável — o `bash -x` mostra a linha como se tivesse dado certo |
| **`forcePathStyle` no SDK da AWS** | sem ele o SDK monta `http://bucket.s3:8333`, que não resolve — e o erro que aparece é de DNS, não de S3 |

---

## Acesso rápido

Daqui, sem precisar lembrar de comando de servidor:

```bash
bun run s3:tunel      # abre o painel do S3 nesta máquina
bun run s3:novo NOME  # bucket + credencial para um projeto
bun run s3:status     # estado do servidor de objetos
bun run s3:backup     # backup sob demanda, na VPS
bun run s3:puxar      # backup e cópia para esta máquina
```

Na VPS:

```bash
ssh root@ssh.chico-figueiredo.com.br      # VPS nova (produção)
ssh root@ssh.lojapopcorn.com.br           # droplet antigo (até o cutover terminar)

docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
systemctl --failed
fail2ban-client status
certbot certificates

# testar um domínio sem depender do DNS
curl -s -o /dev/null --resolve 'dominio:443:191.252.219.183' \
     -w 'HTTP %{http_code} TLS=%{ssl_verify_result}\n' https://dominio/
```

---

## Pendências

- [ ] Virar os 3 DNS restantes (+ `chico.mat.br` e `nova.lojapopcorn.com.br`)
- [ ] **Backup fora da máquina** — resolvido só para o `s3` (`bun run s3:puxar` traz uma
      cópia para cá). O `banco` e o `cache` seguem com backup no mesmo disco
- [ ] Refazer o site do basilio
- [ ] Remover a chave de migração do droplet: `sed -i '/migracao-locaweb/d' /root/.ssh/authorized_keys`
- [ ] Atualizar `TUNEL_HOST`/`DROPLET` nos `config.sh` do focus-scrap e do ia-monitor
- [ ] Commitar no repo `hermes-agent` a correção dos units (`deploy/systemd/`)
- [ ] Snapshot final e destruir o droplet — **só depois** de migrar tudo acima
