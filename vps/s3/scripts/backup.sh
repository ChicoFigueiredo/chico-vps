#!/usr/bin/env bash
# Backup do servidor de objetos compartilhado.
#
# Três coisas, e a segunda é a que quase todo mundo esquece:
#
#   objetos/<bucket>/…     espelho de todos os buckets, incremental
#   iam-DATA.json          usuários, chaves e políticas — sem isto, restaurar
#                          devolve os arquivos mas nenhum projeto autentica
#   lixeira/DATA/…         o que foi apagado ou sobrescrito naquele dia
#
# É 'sync' e não 'copy': o espelho reflete o estado atual, então continua rápido
# com o tempo. Mas nada é descartado de verdade — o --backup-dir desvia para a
# lixeira tudo que sumiria. Apagar por engano, ou um ransomware apagar por você,
# não propaga para o backup no mesmo instante; há a janela da retenção para
# perceber. Foi exatamente isso que faltou em julho de 2026.
set -euo pipefail

DEST=/opt/s3/backups
RETENCAO_DIAS=14
DIA=$(date +%F)

# shellcheck disable=SC1091
. /opt/s3/.env

mkdir -p "$DEST/objetos" "$DEST/lixeira"

# ── 1. Identidades ──────────────────────────────────────────────────────────
# Usuários, chaves de acesso, políticas e grupos, num JSON só. Modo 600: este
# arquivo contém os segredos de todos os projetos.
docker exec s3 sh -c 'echo "s3.iam.export" | weed shell -master=s3:9333' > "$DEST/iam-$DIA.json"
chmod 600 "$DEST/iam-$DIA.json"

# ── 2. Objetos ──────────────────────────────────────────────────────────────
# O rclone roda em container na rede-s3 e fala com o gateway direto, sem passar
# pelo loopback do host. Não instala nada na VPS.
#
# A origem é 'raiz:' sem bucket: nesse formato o rclone trata cada bucket como
# um diretório e varre todos — inclusive os que forem criados depois, sem
# precisar mexer neste script.
docker run --rm \
  --network rede-s3 \
  --user 0:0 \
  -v "$DEST:/backups" \
  -e RCLONE_CONFIG_RAIZ_TYPE=s3 \
  -e RCLONE_CONFIG_RAIZ_PROVIDER=Other \
  -e RCLONE_CONFIG_RAIZ_ENDPOINT=http://s3:8333 \
  -e RCLONE_CONFIG_RAIZ_REGION=us-east-1 \
  -e RCLONE_CONFIG_RAIZ_FORCE_PATH_STYLE=true \
  -e RCLONE_CONFIG_RAIZ_ACCESS_KEY_ID="$S3_ROOT_ACCESS_KEY" \
  -e RCLONE_CONFIG_RAIZ_SECRET_ACCESS_KEY="$S3_ROOT_SECRET_KEY" \
  rclone/rclone:latest \
  sync raiz: /backups/objetos \
    --backup-dir "/backups/lixeira/$DIA" \
    --fast-list \
    --transfers 4 \
    --checkers 8 \
    --stats-one-line \
    --stats 0

# ── 3. Retenção ─────────────────────────────────────────────────────────────
find "$DEST" -maxdepth 1 -type f -name 'iam-*.json' -mtime +$RETENCAO_DIAS -delete
find "$DEST/lixeira" -maxdepth 1 -mindepth 1 -type d -mtime +$RETENCAO_DIAS -exec rm -rf {} +

OBJETOS=$(find "$DEST/objetos" -type f | wc -l)
echo "backup $DIA concluído — $OBJETOS objetos, $(du -sh "$DEST" | cut -f1) no total"
