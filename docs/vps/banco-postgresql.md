# `banco` — PostgreSQL compartilhado da VPS

> **No ar desde 09/AGO/2026** em `root@ssh.chico-figueiredo.com.br`.
> Um servidor, muitos bancos, cada projeto isolado do outro.
>
> Arquivos reais deste serviço: [`vps/banco/`](../../vps/banco/) — o que está aqui é
> cópia fiel do que roda em `/opt/banco`.

---

## Resumo

| | |
|---|---|
| Versão | PostgreSQL **17.10** + pgvector |
| Imagem | `pgvector/pgvector:pg17` |
| Onde mora | `/opt/banco` (dados em `/opt/banco/dados`, bind mount) |
| Memória em repouso | **~28 MB** |
| Porta | `127.0.0.1:5432` — **nunca exposta à internet** |
| Rede Docker | `rede-banco` (externa, compartilhada) |
| Nomes na rede | `banco` · `postgres` · `db` — os três funcionam |
| Backup | diário às 03:20, retenção 14 dias, testado |
| Checksums | ligados (detecta corrupção silenciosa de disco) |

---

## Por que PostgreSQL

Escolhido em vez de MariaDB, Supabase self-hosted ou libSQL por três razões específicas
a esta casa:

1. **O Bun fala Postgres nativamente.** A partir da 1.2, `Bun.sql` vem embutido — mesma
   ergonomia do `bun:sqlite` já usado no focus-scrap e no ia-monitor, sem dependência nova.
2. **A aritmética já roda em Supabase**, que é Postgres. Mesmo dialeto: dá para trazer
   aquele projeto para casa, ou o contrário, sem reescrever query.
3. **pgvector**, para embeddings — algo que o MySQL não oferece e que os projetos de IA
   desta casa provavelmente vão querer.

Supabase self-hosted foi descartado por peso: 8+ containers, 1,5–2 GB, metade da máquina.
Se um dia quiser a DX de API REST, `PostgREST` (~20 MB) roda em cima deste mesmo Postgres.

---

## Criar um banco para um projeto

```bash
novo-banco meuprojeto                    # banco + role isolados
novo-banco meuprojeto vector pg_trgm     # já com extensões habilitadas
```

O script cria o database, o role dono, revoga o `CONNECT` do `PUBLIC` e grava a
credencial em `/opt/banco/credenciais/<nome>.env` (modo 600). Imprime a connection
string pronta.

**Nome válido:** minúsculas, dígitos e `_`, começando por letra. Nada de hífen — o
Postgres dobra identificador não-citado para minúsculo e exige aspas em hífen; barrar
isso na entrada evita um erro obscuro depois.

> ⚠️ **Extensões só o superusuário instala.** `pgvector` e a maioria das outras não são
> *trusted extensions*: o dono do banco **não** consegue rodar `CREATE EXTENSION`. Por
> isso o `novo-banco.sh` aceita extensões como argumento e as cria como `postgres`. Se
> esquecer na criação, rode depois: `banco meuprojeto` → `CREATE EXTENSION vector;`

### Isolamento — verificado, não presumido

```
teste_um tentando entrar em teste_dois  →  FATAL: database "teste_dois" does not exist
teste_um no próprio banco               →  conectado em teste_um como teste_um
```

O Postgres concede `CONNECT` a `PUBLIC` por padrão — sem o `REVOKE` que o script faz,
qualquer role alcançaria o banco de qualquer projeto.

---

## Conectar

### De um container na VPS

Junte o serviço à rede `rede-banco` — ela é **externa**, criada fora de qualquer compose,
justamente para não depender da ordem de subida:

```yaml
services:
  seu-app:
    networks: [sua-rede, rede-banco]
    environment:
      - DATABASE_URL=postgresql://meuprojeto:SENHA@banco:5432/meuprojeto

networks:
  sua-rede:
  rede-banco:
    external: true
```

### Da própria VPS

```bash
banco                 # psql como superusuário
banco meuprojeto      # psql já dentro do database
```

### Da sua máquina (WSL) — por túnel SSH

A 5432 não é alcançável pela internet, de propósito. O caminho é o mesmo padrão que já
funciona no focus e no ia-monitor:

```bash
ssh -N -L 5432:127.0.0.1:5432 root@ssh.chico-figueiredo.com.br
# noutro terminal:
psql postgresql://meuprojeto:SENHA@127.0.0.1:5432/meuprojeto
```

> 💡 Para uso contínuo, vale criar um usuário `tunel-banco` sem shell com
> `permitlisten` restrito, em vez de tunelar como root — mesmo desenho dos outros túneis.

### Do Bun, sem instalar nada

```ts
import { SQL } from "bun";

const db = new SQL(process.env.DATABASE_URL!);

await db`create table if not exists notas (
  id   serial primary key,
  txt  text not null,
  em   timestamptz not null default now()
)`;

await db`insert into notas ${db({ txt: "primeira" })}`;
const linhas = await db`select * from notas order by em desc limit 10`;
```

Comparado ao `bun:sqlite`, a diferença prática é que tudo vira `await` e os parâmetros
entram por interpolação de template — que é escapada, não concatenada.

---

## Backup

Roda todo dia às 03:20 (`banco-backup.timer`), com folga aleatória de até 5 min e
`Persistent=true` — se a máquina estava desligada, roda ao voltar.

```
/opt/banco/backups/
├── globals-2026-08-09.sql.gz      roles e senhas
├── meuprojeto-2026-08-09.dump     um por database, formato custom
└── outroprojeto-2026-08-09.dump
```

**Dois tipos de arquivo, de propósito.** O `globals` guarda roles e senhas: sem ele, um
restore em máquina nova devolve os dados mas nenhum login funciona. Os `.dump` são um por
database, no formato custom do `pg_dump`, o que permite restaurar **um** projeto sem
tocar nos outros.

Retenção: 14 dias.

### Restaurar

```bash
# um database
docker exec -i banco pg_restore -U postgres -d meuprojeto --clean --if-exists \
  < /opt/banco/backups/meuprojeto-2026-08-09.dump

# num banco novo
docker exec banco psql -U postgres -c 'create database meuprojeto_copia;'
docker exec -i banco pg_restore -U postgres -d meuprojeto_copia --no-owner \
  < /opt/banco/backups/meuprojeto-2026-08-09.dump

# roles e senhas (máquina nova)
gunzip -c /opt/banco/backups/globals-2026-08-09.sql.gz | docker exec -i banco psql -U postgres
```

**Testado em 09/AGO/2026**: um dump com dados `vector` foi restaurado em database novo e
a busca por similaridade devolveu as distâncias corretas. Backup que não se testa não é
backup — foi o que transformou o incidente do basilio em perda total.

> ⚠️ **Os backups estão no mesmo disco do banco.** Protegem contra erro humano e
> corrupção lógica, **não** contra perda da máquina. Falta um destino externo — um
> `rclone` para storage de objetos ou um rsync para outra máquina resolveria. Ficou
> pendente de propósito: não há destino definido ainda.

---

## Operação

```bash
# Estado
docker ps --filter name=banco
docker stats banco --no-stream
banco -c '\l'                                    # listar databases
banco -c '\du'                                   # listar roles

# Tamanho de cada database
banco -c "select datname, pg_size_pretty(pg_database_size(datname))
          from pg_database where not datistemplate order by 2 desc;"

# Conexões abertas (max_connections = 50)
banco -c "select datname, usename, state, count(*)
          from pg_stat_activity group by 1,2,3 order by 4 desc;"

# Queries lentas ficam no log (>1s)
docker logs banco --tail 50 | grep duration

# Ciclo de vida
cd /opt/banco && docker compose up -d
cd /opt/banco && docker compose restart
systemctl start banco-backup.service             # backup sob demanda
```

---

## Configuração e as decisões por trás dela

O ajuste vai por **flags no `command:`** do compose, não num `postgresql.conf` próprio.
É deliberado: fica visível junto do resto do serviço e não corre o risco de perder os
padrões do arquivo original ao substituí-lo inteiro.

| Parâmetro | Valor | Por quê |
|---|---|---|
| `shared_buffers` | 256MB | cache do banco; os dados desta casa cabem nisso muitas vezes |
| `effective_cache_size` | 1GB | estimativa do que o SO cacheia — só orienta o planner, não aloca |
| `work_mem` | 8MB | **por operação** de sort/hash, não por conexão |
| `maintenance_work_mem` | 64MB | VACUUM, CREATE INDEX |
| `max_connections` | 50 | folgado para a escala atual |
| `random_page_cost` | 1.1 | SSD: leitura aleatória custa quase o mesmo que sequencial |
| `effective_io_concurrency` | 200 | SSD aguenta muita leitura em paralelo |
| `wal_compression` | on | menos I/O de WAL |
| `checkpoint_completion_target` | 0.9 | espalha a escrita do checkpoint, evita pico de I/O |
| `log_min_duration_statement` | 1000 | registra query que passa de 1s |

Outras escolhas que valem explicação:

- **`shm_size: 256mb`** — o padrão do Docker para `/dev/shm` é 64 MB, apertado para
  queries paralelas. É causa comum de erro obscuro em Postgres containerizado.
- **`--data-checksums`** — só pode ser ligado no `initdb`, **nunca depois**. Custa ~2% de
  CPU e detecta corrupção silenciosa de disco. Ligar na criação é de graça; não ligar
  custa um `pg_dump`/restore inteiro para corrigir.
- **Dados em bind mount, não volume nomeado** — `/opt/banco/dados` é visível, copiável
  por rsync e independente do ciclo de vida do container.
- **`uid 999` reservado** — os usuários de serviço da VPS foram criados a partir do 1001
  justamente para deixar o 999 livre, que é o uid interno do `postgres` (e do `redis`) nos
  containers oficiais. Sem isso, os arquivos do PGDATA apareceriam como propriedade de um
  usuário do host, o que confunde na hora de diagnosticar.
- **PGDATA em `0700` com dono `999:999`** — o Postgres **recusa subir** se o diretório de
  dados for acessível a grupo ou outros.

---

## Onde NÃO usar este banco

**focus-scrap e ia-monitor devem continuar em SQLite.** Eles rodam na máquina de casa,
não na VPS: o banco local é o que faz o painel funcionar com a internet oscilando e o
vídeo sair do disco em tempo real. Apontá-los para cá faria cada query atravessar a
internet — latência em tudo e painel quebrado quando a conexão cair.

Este servidor é para **os projetos hospedados na VPS**. Se um dia mover focus ou
ia-monitor inteiros para cá, aí a conta muda.

---

## Segredos

| O quê | Onde |
|---|---|
| Senha do superusuário `postgres` | `/opt/banco/.env` (modo 600) → copiar para o BitWarden |
| Senha de cada projeto | `/opt/banco/credenciais/<nome>.env` (modo 600) |

Nenhum dos dois vai para o git — o [`.gitignore`](../../.gitignore) do repositório barra
`*.env`, `credenciais/`, `*.dump` e `dados/`.

---

## Recriar do zero

```bash
mkdir -p /opt/banco/{dados,conf,backups,scripts,credenciais}
chown -R 999:999 /opt/banco/dados && chmod 700 /opt/banco/dados
chmod 700 /opt/banco/credenciais
docker network create rede-banco

# compose.yml e scripts vêm de vps/banco/ deste repositório
echo "POSTGRES_PASSWORD=$(openssl rand -base64 30 | tr -d '/+=' | head -c 32)" > /opt/banco/.env
chmod 600 /opt/banco/.env

cd /opt/banco && docker compose up -d
cp vps/banco/systemd/banco-backup.* /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now banco-backup.timer

# restaurar roles e depois cada database
gunzip -c backups/globals-DATA.sql.gz | docker exec -i banco psql -U postgres
```
