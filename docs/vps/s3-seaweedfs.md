# `s3` — armazenamento de objetos compartilhado da VPS

Um servidor de arquivos com a API da AWS S3, na VPS nova. Serve a qualquer
projeto hospedado ali: upload de usuário, anexo, imagem, PDF, backup de app —
tudo que hoje viraria arquivo solto no disco de um container.

Motor: **SeaweedFS 4.41**, Apache-2.0. Do lado da aplicação nada disso aparece:
o código usa `@aws-sdk/client-s3` normalmente, só apontando o endpoint para cá.

---

## Resumo

| | |
|---|---|
| Container | `s3` (servidor) e `s3-admin` (painel) |
| Imagem | `chrislusf/seaweedfs:4.41` |
| API S3 | `127.0.0.1:9000` no host · `http://s3:8333` na rede docker |
| Painel | `127.0.0.1:9001` — **só pelo túnel**, `bun run s3:tunel` |
| Rede docker | `rede-s3` (externa), aliases `s3`, `seaweedfs`, `storage` |
| Dados | `/opt/s3/dados` |
| Memória | ~65 MB o servidor, ~25 MB o painel |
| Backup | diário às 04:00, retenção 14 dias, **restore verificado** |
| Criar projeto | `bun run s3:novo <nome>` ou `/opt/s3/scripts/novo-s3.sh <nome>` |

---

## Por que SeaweedFS, e por que não MinIO

O MinIO era a escolha óbvia, e deixou de ser em duas etapas:

- **MAI/2025** — a administração saiu do console da edição community. Ficou só
  o navegador de objetos; usuário, política e configuração viraram exclusividade
  do produto pago.
- **ABR/2026** — o repositório `minio/minio` foi **arquivado**. Último release
  em outubro de 2025.

Ou seja: adotar MinIO hoje seria colocar os arquivos de todos os projetos num
daemon que não recebe mais correção de segurança. Depois de julho de 2026, essa
não é uma conta que vale a pena fazer.

As alternativas vivas consideradas:

| | Estado | Painel | Nota |
|---|---|---|---|
| **SeaweedFS** | 4.41, maduro, 10+ anos | sim, completo | **escolhido** |
| RustFS | 1.0.0-rc, pré-GA | sim, igual ao MinIO | jovem demais para cópia única |
| versitygw | estável | não tem | objetos viram arquivos comuns em disco |

O SeaweedFS ganhou por ser o único maduro **e** com painel próprio. O preço é
que a compatibilidade S3, embora boa, não é perfeita em recursos avançados
(object lock, alguns cantos de versionamento) — nada que as aplicações daqui
usem.

> Se um dia o motor for trocado, o alias `s3` na rede docker continua válido e
> só o endpoint muda. Foi por isso que o serviço não se chama `seaweedfs`.

---

## Criar um bucket para um projeto

```bash
bun run s3:novo meuprojeto                    # leitura e escrita
bun run s3:novo meuprojeto somente-leitura
```

Cria bucket, usuário e política num passo, e grava a credencial em
`/opt/s3/credenciais/<nome>.env` (modo 600).

> **Nome de bucket não aceita underline.** É minúsculas, dígitos e hífen, de 3 a
> 63 caracteres — regra da AWS, que o SeaweedFS segue. No Postgres o separador
> natural é `_`; aqui, `focus_scrap` precisa virar `focus-scrap`.

### Isolamento — verificado, não presumido

A política anexada a cada usuário nomeia o bucket dele explicitamente, nos dois
ARNs que a AWS exige:

```json
"Resource": ["arn:aws:s3:::meuprojeto", "arn:aws:s3:::meuprojeto/*"]
```

São dois porque `ListBucket` age sobre o bucket e `GetObject` sobre os objetos
dentro dele. Com um só, ou a listagem falha ou a leitura falha.

Testado com dois projetos, `teste-alfa` e `teste-beta`:

| Tentativa | Resultado |
|---|---|
| alfa grava no próprio bucket | ✔ permitido |
| alfa lê o próprio bucket | ✔ permitido |
| alfa grava no bucket do beta | ✔ **403 AccessDenied** |
| alfa lista o bucket do beta | ✔ **403 AccessDenied** |
| alfa lista todos os buckets | ✔ vê **só o próprio** |

O último é o mais interessante: o `ListAllMyBuckets` é filtrado por identidade,
então um projeto nem descobre que os outros existem.

---

## Conectar

No código é a AWS normal. Duas linhas fogem do padrão e ambas são obrigatórias:

```ts
import { S3Client } from "@aws-sdk/client-s3";

const s3 = new S3Client({
  endpoint: process.env.S3_ENDPOINT,   // http://s3:8333
  region: process.env.S3_REGION,       // us-east-1 — exigido, mesmo sem uso
  forcePathStyle: true,                // sem isto, nada funciona
  credentials: {
    accessKeyId:     process.env.S3_ACCESS_KEY_ID,
    secretAccessKey: process.env.S3_SECRET_ACCESS_KEY,
  },
});
```

- **`forcePathStyle`** — o SDK, no padrão, monta o endereço como
  `http://meubucket.s3:8333`, no estilo virtual-host da AWS. Esse nome não
  resolve na rede docker e o erro que aparece é de DNS, não de S3.
- **`region`** — o SeaweedFS não usa região nenhuma, mas o SDK recusa assinar a
  requisição sem uma. `us-east-1` é convenção.

### De um container na VPS

```yaml
services:
  seu-app:
    networks: [sua-rede, rede-s3]
    env_file: /opt/s3/credenciais/seuprojeto.env
networks:
  rede-s3:
    external: true
```

### Da própria VPS

```bash
S3_ENDPOINT=http://127.0.0.1:9000
```

### Da sua máquina — pelo túnel

```bash
bun run s3:tunel
# e então S3_ENDPOINT=http://127.0.0.1:9000
```

---

## O painel de administração

```bash
bun run s3:tunel
```

Abre `http://127.0.0.1:9001` no navegador e imprime usuário e senha. Dali dá
para navegar nos arquivos, criar e apagar bucket, e gerir usuários da API.

**Por que só pelo túnel.** As portas 9000 e 9001 não existem para a internet, e
não por regra de firewall: o `ports:` do compose tem o prefixo `127.0.0.1:`,
então o Docker escreve a regra de NAT presa ao loopback —

```
-A DOCKER -d 127.0.0.1/32 ... --dport 9001 -j DNAT --to-destination 172.18.0.3:23646
```

— e o pacote que chega pela internet simplesmente não casa com ela. Verificado
de fora: 9000 e 9001 inalcançáveis, 443 respondendo no mesmo teste.

> Isto é proteção **de verdade**, e é importante entender por quê: o UFW **não**
> bloqueia porta publicada por container, porque o Docker escreve no `iptables`
> abaixo dele. Uma regra `ufw deny 9001` daria sensação de segurança sem
> entregar nenhuma. Quem protege aqui é o `127.0.0.1:` do compose — se alguém um
> dia tirar esse prefixo, a porta fica exposta e o UFW não vai salvar.

O túnel encaminha `-L 127.0.0.1:9001:...` com o endereço explícito: sem ele o
`ssh` escutaria em todas as interfaces e qualquer um no mesmo Wi-Fi abriria o
painel.

O login tem proteção CSRF e foi verificado: senha certa vai para `/admin`, senha
errada volta com `Invalid credentials`, e sem sessão o painel redireciona para
o login.

---

## Backup

Roda todo dia às 04:00 (`s3-backup.timer`), em fila com o banco (03:20) e o
cache (03:40) para não disputarem I/O. Sob demanda:

```bash
bun run s3:backup     # gera na VPS, agora
bun run s3:puxar      # gera e traz uma cópia para esta máquina
```

Três coisas em `/opt/s3/backups/`:

```
objetos/<bucket>/…     espelho de todos os buckets, incremental
iam-DATA.json          usuários, chaves e políticas
lixeira/DATA/…         o que foi apagado ou sobrescrito naquele dia
```

**O `iam-DATA.json` é o que quase todo mundo esquece.** É o análogo do
`globals.sql` do Postgres e do `users.acl` do Redis: sem ele, restaurar devolve
os arquivos e nenhum projeto consegue autenticar.

**A lixeira é a lição de julho.** O comando é `rclone sync`, então o espelho
reflete o estado atual e o backup continua rápido com o tempo. Mas o
`--backup-dir` desvia para a lixeira tudo que sumiria em vez de descartar. Apagar
por engano — ou um ransomware apagar por você — não propaga para o backup no
mesmo instante: há a janela da retenção, 14 dias, para perceber.

Verificado: objeto apagado do bucket desapareceu do espelho e reapareceu
íntegro em `lixeira/2026-08-11/`.

> O `rclone` roda em container na `rede-s3` e fala com o gateway direto. Não há
> nada instalado na VPS para isso.

### Restaurar — verificado

Testado apagando usuário e bucket e trazendo os dois de volta. A credencial
original voltou a funcionar sem tocar em nada na aplicação.

```bash
# 1. identidades (usuários, chaves, políticas) — sobrescreve TUDO, daí o -apply
cp /opt/s3/backups/iam-2026-08-11.json /opt/s3/dados/iam-restore.json
s3 s3.iam.import -file /data/iam-restore.json -apply
rm /opt/s3/dados/iam-restore.json

# 2. o bucket em si — o import de identidades não recria buckets
s3 s3.bucket.create -name meuprojeto

# 3. os objetos
docker run --rm --network rede-s3 --user 0:0 -v /opt/s3/backups:/backups \
  -e RCLONE_CONFIG_R_TYPE=s3 -e RCLONE_CONFIG_R_PROVIDER=Other \
  -e RCLONE_CONFIG_R_ENDPOINT=http://s3:8333 -e RCLONE_CONFIG_R_REGION=us-east-1 \
  -e RCLONE_CONFIG_R_FORCE_PATH_STYLE=true -e RCLONE_CONFIG_R_NO_CHECK_BUCKET=true \
  -e RCLONE_CONFIG_R_ACCESS_KEY_ID=raiz \
  -e RCLONE_CONFIG_R_SECRET_ACCESS_KEY="$(grep -oP '^S3_ROOT_SECRET_KEY=\K.*' /opt/s3/.env)" \
  rclone/rclone:latest copy /backups/objetos/meuprojeto r:meuprojeto/
```

O caminho passa por `/opt/s3/dados` porque o `weed shell` lê o arquivo **de
dentro do container**, e essa pasta é a que está montada lá (em `/data`).

> A cópia da VPS mora no mesmo disco: protege contra erro humano e corrupção,
> não contra perder a máquina. O `bun run s3:puxar` resolve isso trazendo tudo
> para cá — é a pendência de backup externo que ficou aberta desde julho.

---

## Operação

```bash
bun run s3:status          # containers, buckets, usuários, disco, timer

s3                         # weed shell interativo
s3 s3.bucket.list          # buckets e tamanho
s3 s3.user.list            # usuários da API
s3 s3.config.show          # resumo do IAM
s3 s3.bucket.quota -name meuprojeto -size 5 -unit GiB
s3 s3.bucket.versioning -name meuprojeto -state Enabled

# ciclo de vida
docker compose -f /opt/s3/compose.yml up -d
docker compose -f /opt/s3/compose.yml restart s3-admin
systemctl list-timers s3-backup.timer
```

---

## Armadilhas encontradas

Todas custaram tempo durante a montagem, e todas voltariam a morder.

### O gateway S3 nasce **aberto**

Sem identidade configurada, o SeaweedFS aceita tudo anonimamente. Antes do
`bootstrap`, um `curl` sem credencial nenhuma criou bucket, gravou e leu:

```
PUT /teste-anonimo        → HTTP 200
PUT /teste-anonimo/x.txt  → HTTP 200
```

É a mesma classe de falha do phpMyAdmin que custou o banco do basilio. Fecha-se
criando a identidade raiz — depois disso, tudo sem credencial devolve 403.
**Ao recriar do zero, o passo do bootstrap não é opcional.**

### O ponto de montagem precisa ser `/data`

O entrypoint da imagem roda como root, corrige a dona da pasta montada e só
então larga o privilégio para o usuário `seaweed` (uid 1000). Só que ele conhece
um caminho só: `/data`. Montado em qualquer outro lugar, o processo fica sem
escrita e o erro é:

```
please verify /dados is writable ... mkdir /dados/m9333: permission denied
```

que não sugere nem de longe que a causa é o nome do caminho.

### `pipefail` + `/dev/urandom` + `head` = script morre calado

```bash
CHAVE="$(tr -dc 'A-Z0-9' </dev/urandom | head -c 20)"   # ⚠
```

`/dev/urandom` é infinito: quando o `head` fecha o cano, o `tr` morre de SIGPIPE
(141), o `pipefail` propaga e o `set -e` encerra o script — **depois** de a
variável já ter sido atribuída, então o `bash -x` mostra a linha como se tivesse
dado certo. Com `openssl`, cuja saída é finita, não acontece.

```bash
CHAVE="$(openssl rand -hex 10 | tr 'a-f' 'A-F')"        # ✔ 20 caracteres
```

Vale para os scripts do `banco` e do `cache` também: eles escapam por sorte,
porque a saída do `openssl` deles é pequena o bastante para caber no buffer do
cano antes de o `head` sair.

### `rclone` precisa de `--s3-no-check-bucket`

O rclone chama `CreateBucket` antes do primeiro upload só para garantir que o
destino existe. A política do projeto não dá esse poder, então o upload falha
com `AccessDenied: CreateBucket` — mensagem que culpa a operação errada e parece
falta de permissão de escrita.

Pôr `s3:CreateBucket` na política **não resolve**: o SeaweedFS trata criação de
bucket como privilégio global e nega mesmo com o ARN do próprio bucket listado.
Testado. A solução fica no cliente:

```bash
rclone ... --s3-no-check-bucket
```

Os SDKs da AWS não fazem essa chamada — aplicação nenhuma sente isso, só
ferramenta de linha de comando.

### Telemetria ligada por padrão

A imagem reporta estatística anônima de uso para `telemetry.seaweedfs.com` a
cada 24 h. Desligada com `-master.telemetry=false`.

---

## Segredos

| O quê | Onde |
|---|---|
| Senha do painel | `/opt/s3/.env` (600) → `S3_ADMIN_PASSWORD` |
| Chave raiz da API | `/opt/s3/.env` (600) → `S3_ROOT_*` |
| Credencial de cada projeto | `/opt/s3/credenciais/<nome>.env` (600) |

Nada disso entra no git — o `.gitignore` barra `*.env` e `credenciais/`. O
espelho local do `bun run s3:puxar` cai em `backups-s3/`, também barrado, e
contém o `iam-*.json` com **os segredos de todos os projetos em texto claro**.
Guarde as senhas no BitWarden.

---

## Recriar do zero

```bash
# compose.yml, scripts/ e systemd/ vêm de vps/s3/ deste repositório
mkdir -p /opt/s3/{dados,dados-admin,backups,credenciais}
chmod 700 /opt/s3/credenciais
docker network create rede-s3

# .env com as quatro variáveis
cat > /opt/s3/.env <<EOF
S3_ADMIN_USER=chico
S3_ADMIN_PASSWORD=$(openssl rand -base64 30 | tr -d '/+=' | head -c 32)
S3_ROOT_ACCESS_KEY=raiz
S3_ROOT_SECRET_KEY=$(openssl rand -base64 30 | tr -d '/+=' | head -c 40)
EOF
chmod 600 /opt/s3/.env

docker compose -f /opt/s3/compose.yml up -d

# BOOTSTRAP — sem isto o S3 fica aberto para qualquer um
/opt/s3/scripts/bootstrap.sh

cp /opt/s3/systemd/s3-backup.* /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now s3-backup.timer

# restaurar, se for migração: ver "Restaurar" acima
```
