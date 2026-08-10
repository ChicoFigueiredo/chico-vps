#!/usr/bin/env bash
# Backup diário do Redis compartilhado.
#
# Dois arquivos, e o segundo é o que quase todo mundo esquece:
#   dump-DATA.rdb.gz   os dados
#   users-DATA.acl     os usuários ACL — sem eles, restaurar devolve as chaves
#                      mas nenhum projeto consegue autenticar
set -euo pipefail

DEST=/opt/cache/backups
RETENCAO_DIAS=14
DIA=$(date +%F)
ADMIN=$(grep -oP '^REDIS_PASSWORD=\K.*' /opt/cache/.env)

mkdir -p "$DEST"

# BGSAVE é assíncrono: dispara e retorna. Comparar o lastsave antes/depois é
# como se sabe que o snapshot NOVO terminou, em vez de copiar o anterior.
ANTES=$(docker exec -e R="$ADMIN" cache sh -c 'redis-cli -a "$R" --no-auth-warning LASTSAVE')
docker exec -e R="$ADMIN" cache sh -c 'redis-cli -a "$R" --no-auth-warning BGSAVE' >/dev/null

for _ in $(seq 1 60); do
  AGORA=$(docker exec -e R="$ADMIN" cache sh -c 'redis-cli -a "$R" --no-auth-warning LASTSAVE')
  [ "$AGORA" != "$ANTES" ] && break
  sleep 1
done
[ "$AGORA" != "$ANTES" ] || { echo "BGSAVE não completou em 60s" >&2; exit 1; }

gzip -c /opt/cache/dados/dump.rdb > "$DEST/dump-$DIA.rdb.gz"
cp /opt/cache/dados/users.acl "$DEST/users-$DIA.acl"
chmod 600 "$DEST/users-$DIA.acl"

find "$DEST" -type f \( -name '*.rdb.gz' -o -name '*.acl' \) -mtime +$RETENCAO_DIAS -delete

echo "backup $DIA concluído — $(du -sh "$DEST" | cut -f1) no total"
