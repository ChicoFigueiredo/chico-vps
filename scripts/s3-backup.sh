#!/usr/bin/env bash
# Dispara o backup do servidor de objetos, agora, da sua máquina.
#
#   bun run s3:backup
#
# O mesmo script que o systemd roda às 04:00 — só que sob demanda, antes de uma
# mudança arriscada. É incremental: a primeira vez copia tudo, as seguintes só
# a diferença.
#
# Isto grava o backup NA VPS. Para trazer uma cópia para cá, que é o que
# protege contra perder a máquina inteira, veja 'bun run s3:puxar'.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
. scripts/comum.sh

exige_vps

echo
cinza "  rodando /opt/s3/scripts/backup.sh em $VPS…"
echo

# O NOTICE do rclone sobre não achar arquivo de configuração é esperado — ele é
# configurado por variável de ambiente — e só polui a saída.
ssh "$VPS" '/opt/s3/scripts/backup.sh' 2>&1 | grep -v 'Config file .* not found'

echo
ssh "$VPS" '
  echo "  espelho:   $(find /opt/s3/backups/objetos -type f 2>/dev/null | wc -l) objetos, $(du -sh /opt/s3/backups/objetos 2>/dev/null | cut -f1)"
  echo "  lixeira:   $(find /opt/s3/backups/lixeira -type f 2>/dev/null | wc -l) arquivos guardados"
  echo "  identidades: $(ls -1 /opt/s3/backups/iam-*.json 2>/dev/null | wc -l) exportações"
'
echo
verde "  backup concluído."
cinza "  para trazer uma cópia para esta máquina:  bun run s3:puxar"
echo
