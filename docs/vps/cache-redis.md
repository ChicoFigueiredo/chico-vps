# `cache` — Redis compartilhado da VPS

> **No ar desde 09/AGO/2026** em `root@ssh.chico-figueiredo.com.br`.
> Sobe **ao lado** do Redis do bolão, que segue intocado até o bolão ser remodelado.
>
> Arquivos reais: [`vps/cache/`](../../vps/cache/) · Irmão deste: [banco-postgresql.md](banco-postgresql.md)

---

## Resumo

| | |
|---|---|
| Versão | Redis **8.10** (alpine) |
| Onde mora | `/opt/cache` (dados em `/opt/cache/dados`, bind mount) |
| Memória em repouso | **~5 MB** (teto de 256 MB) |
| Porta no host | `127.0.0.1:`**`6380`** — a 6379 é do bolão |
| Rede Docker | `rede-cache` (externa, compartilhada) |
| Nomes na rede | `cache` · `redis` |
| Isolamento | ACL por usuário + prefixo de chave |
| Persistência | AOF (`everysec`) + snapshots RDB |
| Política de memória | `volatile-lru` |
| Backup | diário às 03:40, retenção 14 dias |

---

## Os dois Redis convivendo

Foi pedido explicitamente: duplicar o recurso até o bolão ser remodelado.

| | `cache` (novo, compartilhado) | `cache.bolao.maxmat1.com.br` (antigo) |
|---|---|---|
| Porta no host | `127.0.0.1:6380` | `127.0.0.1:6379` |
| Rede | `rede-cache` | `rede-maxmat1` |
| Usado por | projetos novos | só o bolão |
| Memória | ~5 MB | ~11 MB |

**Por que 6380.** A 6379 do host já estava tomada pelo container do bolão. Dentro do
Docker não há conflito nenhum — os dois escutam 6379 em containers diferentes; a porta do
host só existe para túnel SSH e depuração a partir da própria VPS.

### Quando remodelar o bolão

O bolão hoje conecta pelo nome do container, com senha em texto no `docker-compose.yaml`:

```yaml
- CACHE_URL=cache.bolao.maxmat1.com.br
- CACHE_PORT=6379
- CACHE_PW=eYVX...
```

A migração, quando quiser:

```bash
novo-cache bolao                              # cria o usuário ACL
# aponte o app para cache:6379 com a credencial nova,
# prefixando as chaves com 'bolao:'
cd /opt/bolao-maxmat1 && docker compose up -d
# só depois de validar:
docker compose stop cache.bolao.maxmat1.com.br
```

> 💡 Os dados do Redis do bolão são **cache puro** (`--save 20 1`, sem AOF) — perdê-los
> não custa nada além de um aquecimento. Não há migração de dados a fazer, só de config.

---

## Criar acesso para um projeto

```bash
novo-cache meuprojeto
```

Cria um usuário ACL restrito a chaves e canais `meuprojeto:*`, grava a credencial em
`/opt/cache/credenciais/meuprojeto.env` (modo 600) e persiste com `ACL SAVE`.

### Prefixo de chave não é opcional

**Toda chave precisa começar com `<projeto>:`** — a ACL recusa o resto. Nos clientes isso
é uma linha de configuração:

```ts
// ioredis — tem keyPrefix nativo
new Redis(process.env.REDIS_URL, { keyPrefix: "meuprojeto:" })

// Bun.redis / node-redis — sem keyPrefix; prefixe à mão ou envolva o cliente
const K = (k: string) => `meuprojeto:${k}`;
await redis.set(K("sessao:42"), valor);
```

### Por que ACL e não "um database por projeto"

O Redis tem 16 databases numerados (`SELECT 0..15`), e é tentador usar um por projeto.
**Eles não isolam nada**: qualquer cliente autenticado pode dar `SELECT` em todos e ler o
que quiser. São namespaces, não fronteiras.

Isolamento de verdade no Redis é ACL — usuário restrito por padrão de chave (`~proj:*`),
por canal de pub/sub (`&proj:*`) e por comando.

### Isolamento — verificado, não presumido

Testado em 09/AGO/2026 com dois usuários:

| Tentativa | Resultado |
|---|---|
| escrever no próprio prefixo | ✅ `OK` |
| ler chave de outro projeto | `NOPERM No permissions to access a key` |
| chave sem prefixo | `NOPERM No permissions to access a key` |
| `FLUSHALL` | `NOPERM User proj_um has no permissions to run the 'flushall' command` |
| `KEYS *` | `NOPERM ... to run the 'keys' command` |

As senhas ficam no `users.acl` como **hash SHA-256**, não em texto — o `ACL SAVE` converte.

---

## `volatile-lru` — a decisão que mais importa

Num Redis compartilhado a política de despejo é onde se ganha ou se perde:

| Política | O que faria aqui |
|---|---|
| `allkeys-lru` | despejaria **qualquer** chave sob pressão — inclusive a fila de jobs ou a sessão de outro projeto, **em silêncio** |
| `noeviction` | o cache de um projeto encheria a memória e **derrubaria a escrita de todos** |
| **`volatile-lru`** ✅ | só despeja chave **que tem TTL** — o que o próprio app marcou como descartável |

Com `volatile-lru`, quem usa o Redis como cache põe TTL e aceita perder; quem usa para
fila ou sessão não põe TTL e não perde. Os dois usos convivem no mesmo servidor.

> ⚠️ **A consequência a conhecer:** se a memória encher e não houver chave com TTL,
> as escritas passam a falhar com erro OOM em vez de apagar dado de alguém. É o
> comportamento correto — um erro visível vale mais que um sumiço silencioso. Se isso
> acontecer, o caminho é subir o `maxmemory` no `conf/redis.conf` ou revisar quem está
> gravando sem TTL.

---

## Conectar

### De um container na VPS

```yaml
services:
  seu-app:
    networks: [sua-rede, rede-cache]
    environment:
      - REDIS_URL=redis://meuprojeto:SENHA@cache:6379

networks:
  sua-rede:
  rede-cache:
    external: true
```

> 💡 Um projeto que use os dois serviços entra nas duas redes:
> `networks: [sua-rede, rede-banco, rede-cache]`. Redes separadas são de propósito —
> quem só precisa de cache não ganha rota até o Postgres.

### Da própria VPS

```bash
cache                  # redis-cli interativo como admin
cache DBSIZE           # executa e sai
cache ACL LIST         # ver os usuários
```

### Da sua máquina — por túnel SSH

```bash
ssh -N -L 6380:127.0.0.1:6380 root@ssh.chico-figueiredo.com.br
redis-cli -u redis://meuprojeto:SENHA@127.0.0.1:6380
```

---

## Backup

Diário às 03:40 — 20 minutos depois do Postgres, para os dois não disputarem I/O.

```
/opt/cache/backups/
├── dump-2026-08-09.rdb.gz     os dados
└── users-2026-08-09.acl       os usuários ACL
```

**O `users.acl` é o arquivo que quase todo mundo esquece.** Sem ele, restaurar devolve as
chaves mas nenhum projeto consegue autenticar.

O script não confia no `BGSAVE` cegamente: ele é assíncrono, então compara o `LASTSAVE`
antes e depois para garantir que copiou o snapshot **novo**, e não o anterior.

### Restaurar

```bash
cd /opt/cache && docker compose down
gunzip -c backups/dump-2026-08-09.rdb.gz > dados/dump.rdb
cp backups/users-2026-08-09.acl dados/users.acl
chown 999:999 dados/dump.rdb dados/users.acl && chmod 600 dados/users.acl
# O AOF tem precedência sobre o RDB no boot — precisa sair do caminho.
mv dados/appendonlydir dados/appendonlydir.old
docker compose up -d
```

> ⚠️ **`appendonly yes` faz o Redis ignorar o `dump.rdb` no boot** e carregar o AOF.
> Restaurar um RDB sem tirar o `appendonlydir` do caminho devolve um Redis com os dados
> antigos e a impressão de que o backup falhou.

> ⚠️ Os backups estão no mesmo disco. Protegem contra erro humano, não contra perder a
> máquina. Vale um destino externo — mesma pendência do Postgres.

---

## Operação

```bash
cache INFO memory | grep -E 'used_memory_human|maxmemory_human'
cache INFO keyspace
cache ACL LIST
cache --scan --pattern 'meuprojeto:*' | head

# quanto cada projeto ocupa (aproximado, por prefixo)
cache --scan --pattern 'meuprojeto:*' | wc -l

docker logs cache --tail 50
cd /opt/cache && docker compose restart
systemctl start cache-backup.service        # backup sob demanda
```

---

## Decisões de configuração

- **`protected-mode no`** — desligado de propósito. A proteção real são três camadas: a
  porta só existe em `127.0.0.1`, só quem entra em `rede-cache` enxerga o container, e
  todo usuário precisa de senha (inclusive o `default`, via `aclfile`). O protected-mode
  existe para o caso de um Redis sem senha exposto; mantê-lo ligado junto de
  `bind 0.0.0.0` só confunde o diagnóstico.
- **`aclfile`** em vez de `requirepass` — permite criar usuários em tempo de execução
  (`ACL SETUSER` + `ACL SAVE`) e faz isso sobreviver a restart. `requirepass` e `aclfile`
  definindo o mesmo `default` entram em conflito; usamos só o segundo.
- **AOF + RDB juntos** — o AOF dá durabilidade de 1 segundo (é o que permite usar este
  Redis para fila e sessão, não só cache); o RDB dá um arquivo único e coerente para o
  backup diário.
- **`uid 999`** — o mesmo motivo do Postgres: é o uid do `redis` nos containers oficiais,
  e foi deixado livre quando os usuários de serviço da VPS foram criados a partir do 1001.

### Dois bugs encontrados e corrigidos nos atalhos

Valem registro porque voltariam a morder:

1. **`docker exec -t` falha sem terminal.** O primeiro `cache` usava `-it` fixo e quebrava
   dentro de script.
2. **`docker exec -i` consome o stdin do chamador.** Com `-i`, o atalho engolia as linhas
   seguintes do script que o chamou — o sintoma era o script parar sem erro.

Os dois atalhos ([`vps/bin/`](../../vps/bin/)) agora usam `-it` **apenas** no modo
interativo (sem argumentos) e nenhum dos dois no modo comando.

---

## Segredos

| O quê | Onde |
|---|---|
| Senha do usuário `default` (admin) | `/opt/cache/.env` (modo 600) → BitWarden |
| Senha de cada projeto | `/opt/cache/credenciais/<nome>.env` (modo 600) |
| Hashes dos usuários ACL | `/opt/cache/dados/users.acl` (SHA-256, modo 600) |

Nada disso vai para o git — o [`.gitignore`](../../.gitignore) barra `*.env`,
`credenciais/`, `dados/` e `backups/`.

---

## Recriar do zero

```bash
mkdir -p /opt/cache/{dados,conf,backups,scripts,credenciais}
chown -R 999:999 /opt/cache/dados && chmod 700 /opt/cache/credenciais
docker network create rede-cache

# compose.yml, conf/ e scripts/ vêm de vps/cache/ deste repositório
SENHA=$(openssl rand -base64 30 | tr -d '/+=' | head -c 32)
echo "REDIS_PASSWORD=$SENHA" > /opt/cache/.env && chmod 600 /opt/cache/.env
echo "user default on >$SENHA ~* &* +@all" > /opt/cache/dados/users.acl
chown 999:999 /opt/cache/dados/users.acl && chmod 600 /opt/cache/dados/users.acl

cd /opt/cache && docker compose up -d
cp vps/cache/systemd/cache-backup.* /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now cache-backup.timer
```
