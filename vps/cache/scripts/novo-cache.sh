#!/usr/bin/env bash
# Cria um usuário ACL isolado no Redis compartilhado.
#
#   /opt/cache/scripts/novo-cache.sh meuprojeto
#
# O usuário criado só enxerga chaves e canais com o prefixo '<projeto>:'.
# O Redis não tem "databases isolados" de verdade — os 16 numerados são
# apenas namespaces sem controle de acesso, e qualquer cliente pode dar
# SELECT em todos. Isolamento real, no Redis, é ACL + prefixo de chave.
set -euo pipefail

NOME="${1:-}"
[[ -n "$NOME" ]] || { echo "uso: $0 <nome-do-projeto>" >&2; exit 1; }
[[ "$NOME" =~ ^[a-z][a-z0-9_-]{1,40}$ ]] || {
  echo "nome inválido: minúsculas, dígitos, _ e -, começando por letra" >&2; exit 1; }

ADMIN=$(grep -oP '^REDIS_PASSWORD=\K.*' /opt/cache/.env)
rcli() { docker exec -e R="$ADMIN" -i cache sh -c 'redis-cli -a "$R" --no-auth-warning "$@"' _ "$@"; }

if rcli ACL GETUSER "$NOME" 2>/dev/null | grep -q .; then
  echo "usuário '$NOME' já existe — nada feito." >&2
  echo "credencial: /opt/cache/credenciais/$NOME.env" >&2
  exit 0
fi

SENHA=$(openssl rand -base64 30 | tr -d '/+=' | head -c 32)

#  on           usuário ativo
#  ~NOME:*      só chaves com esse prefixo
#  &NOME:*      só canais pub/sub com esse prefixo
#  +@all        todos os comandos...
#  -@dangerous  ...menos FLUSHALL, FLUSHDB, KEYS, SHUTDOWN, DEBUG, CONFIG
#  -@admin      ...e menos os administrativos
rcli ACL SETUSER "$NOME" on ">$SENHA" "~$NOME:*" "&$NOME:*" +@all -@dangerous -@admin >/dev/null
rcli ACL SAVE >/dev/null   # persiste em /data/users.acl, sobrevive a restart

CRED="/opt/cache/credenciais/$NOME.env"
cat > "$CRED" <<VARS
# Redis '$NOME' — criado em $(date -Iseconds)
# Todas as chaves DEVEM começar com '$NOME:' — a ACL recusa o resto.
# De dentro de um container (precisa estar na rede 'rede-cache'):
REDIS_URL=redis://$NOME:$SENHA@cache:6379
# Da própria VPS, ou pela ponta de um túnel SSH:
REDIS_URL_LOCAL=redis://$NOME:$SENHA@127.0.0.1:6380
REDIS_PREFIX=$NOME:
VARS
chmod 600 "$CRED"

cat <<FIM

  Usuário de cache '$NOME' criado.

  Credencial salva em: $CRED

  ⚠ Toda chave precisa do prefixo '$NOME:' — a ACL recusa qualquer outra.
    Nos clientes isso é uma linha de configuração, não trabalho em cada chamada:

      ioredis     new Redis(url, { keyPrefix: "$NOME:" })
      node-redis  createClient({ url })   // e prefixe à mão, não tem keyPrefix
      Bun.redis   new RedisClient(url)    // prefixe à mão

  De um container na VPS — junte-o à rede 'rede-cache':

      services:
        seu-app:
          networks: [sua-rede, rede-cache]
      networks:
        rede-cache:
          external: true

      REDIS_URL=redis://$NOME:***@cache:6379

  Da sua máquina, por túnel SSH:

      ssh -N -L 6380:127.0.0.1:6380 root@ssh.chico-figueiredo.com.br
      REDIS_URL=redis://$NOME:***@127.0.0.1:6380

FIM
