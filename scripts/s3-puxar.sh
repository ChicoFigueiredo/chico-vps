#!/usr/bin/env bash
# Traz o backup da VPS para esta máquina.
#
#   bun run s3:puxar                    # para ./backups-s3/
#   DESTINO=/mnt/d/backups bun run s3:puxar
#
# Esta é a peça que faltava desde julho de 2026. O backup na VPS protege contra
# apagar por engano e contra corrupção, mas mora no MESMO disco: não protege
# contra perder a máquina. Uma cópia aqui, sim.
#
# Roda um backup antes de puxar, para não trazer uma foto velha.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
. scripts/comum.sh

DESTINO="${DESTINO:-$PWD/backups-s3}"

exige_vps

echo
cinza "  1/2 — gerando backup fresco na VPS…"
ssh "$VPS" '/opt/s3/scripts/backup.sh' 2>&1 | grep -v 'Config file .* not found' | sed 's/^/      /'

echo
cinza "  2/2 — copiando para $DESTINO…"
mkdir -p "$DESTINO"

# -a preserva data e permissão; --delete faz esta cópia refletir a de lá, sem
# acumular lixo de execuções antigas. O que precisava sobreviver a um apagão já
# está na lixeira do lado de lá, que vem junto.
rsync -a --delete --info=stats1,progress2 \
  "$VPS:/opt/s3/backups/" "$DESTINO/"

# O export de identidades traz os segredos de todos os projetos em texto claro.
chmod 700 "$DESTINO"
chmod 600 "$DESTINO"/iam-*.json 2>/dev/null || true

echo
verde "  backup em $DESTINO"
cinza "  contém os segredos de todos os projetos — mantenha fora do git e fora de nuvem alheia."
echo
