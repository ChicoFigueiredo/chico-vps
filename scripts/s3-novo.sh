#!/usr/bin/env bash
# Cria bucket + credencial para um projeto, sem precisar entrar na VPS.
#
#   bun run s3:novo meuprojeto
#   bun run s3:novo meuprojeto somente-leitura
#
# Mostra a credencial gerada no fim. Ela também fica guardada na VPS, em
# /opt/s3/credenciais/<nome>.env, modo 600.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
. scripts/comum.sh

NOME="${1:-}"
PAPEL="${2:-leitura-escrita}"

if [[ -z "$NOME" ]]; then
  vermelho "falta o nome do projeto"
  cinza "  uso: bun run s3:novo <nome> [leitura-escrita|somente-leitura]"
  exit 1
fi

exige_vps

ssh "$VPS" "/opt/s3/scripts/novo-s3.sh '$NOME' '$PAPEL'"

echo
negrito "  Credencial de '$NOME'"
echo
ssh "$VPS" "cat /opt/s3/credenciais/'$NOME'.env" | sed 's/^/    /'
echo
cinza "  guarde no BitWarden — nada disso entra no git."
echo
