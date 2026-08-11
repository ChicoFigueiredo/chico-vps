#!/usr/bin/env bash
# Estado do servidor de objetos, de relance.
#
#   bun run s3:status
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
. scripts/comum.sh

exige_vps

echo
negrito "  Containers"
ssh "$VPS" 'docker ps --filter name=^s3 --format "{{.Names}}\t{{.Status}}"' | sed 's/^/    /'

echo
negrito "  Buckets"
BUCKETS=$(ssh "$VPS" 'docker exec s3 sh -c "echo s3.bucket.list | weed shell -master=s3:9333"' 2>/dev/null || true)
if [[ -z "${BUCKETS// /}" ]]; then
  cinza "    nenhum ainda — crie com  bun run s3:novo <projeto>"
else
  printf '%s\n' "$BUCKETS" | sed 's/^ */    /'
fi

echo
negrito "  Usuários"
ssh "$VPS" 'docker exec s3 sh -c "echo s3.user.list | weed shell -master=s3:9333"' 2>/dev/null \
  | sed 's/^/    /'

echo
negrito "  Disco e backup"
ssh "$VPS" '
  echo "    dados:   $(du -sh /opt/s3/dados 2>/dev/null | cut -f1)"
  echo "    backup:  $(du -sh /opt/s3/backups 2>/dev/null | cut -f1)"
  echo "    último:  $(ls -1t /opt/s3/backups/iam-*.json 2>/dev/null | head -1 | sed "s#.*/iam-##;s#\.json##" || echo nenhum)"
'

echo
negrito "  Timer do backup"
ssh "$VPS" 'systemctl list-timers s3-backup.timer --no-pager 2>/dev/null | head -2 | sed "s/^/    /"'
echo
