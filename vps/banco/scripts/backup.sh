#!/usr/bin/env bash
# Backup diário do servidor 'banco'.
#
# Dois tipos de arquivo, de propósito:
#   globals-DATA.sql.gz  roles e senhas — sem isto, restaurar numa máquina nova
#                        devolve os dados mas nenhum login funciona
#   <db>-DATA.dump       um por database, formato custom do pg_dump, que permite
#                        restaurar UM projeto sem tocar nos outros
set -euo pipefail

DEST=/opt/banco/backups
RETENCAO_DIAS=14
DIA=$(date +%F)

mkdir -p "$DEST"

docker exec banco pg_dumpall -U postgres --globals-only | gzip > "$DEST/globals-$DIA.sql.gz"

# -Fc (custom) já sai comprimido; não passa por gzip de novo.
docker exec banco psql -U postgres -tAc \
  "select datname from pg_database where not datistemplate and datname <> 'postgres'" |
while read -r db; do
  [ -n "$db" ] || continue
  docker exec banco pg_dump -U postgres -Fc "$db" > "$DEST/$db-$DIA.dump"
done

find "$DEST" -type f \( -name '*.dump' -o -name '*.sql.gz' \) -mtime +$RETENCAO_DIAS -delete

echo "backup $DIA concluído — $(find "$DEST" -maxdepth 1 -name "*-$DIA.*" | wc -l) arquivos, $(du -sh "$DEST" | cut -f1) no total"
