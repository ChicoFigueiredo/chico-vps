#!/usr/bin/env bash
# Abre o painel de administração do servidor de objetos nesta máquina.
#
#   bun run s3:tunel
#
# O painel escuta só em 127.0.0.1 na VPS e as portas 9000/9001 não existem para
# a internet — o UFW só deixa passar 22, 80 e 443. Este script constrói um túnel
# SSH e traz as duas pontas para o seu 127.0.0.1:
#
#   http://127.0.0.1:9001   painel: buckets, usuários e navegador de arquivos
#   http://127.0.0.1:9000   a própria API S3, para rclone/aws-cli daqui
#
# O '-L 127.0.0.1:porta' é deliberado: sem o endereço explícito, o ssh escuta em
# todas as interfaces e qualquer um no mesmo Wi-Fi abriria o seu painel.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
. scripts/comum.sh

exige_vps

for p in "$PORTA_ADMIN" "$PORTA_API"; do
  if porta_ocupada "$p"; then
    vermelho "a porta $p já está ocupada nesta máquina"
    cinza "  feche quem está usando, ou rode com outra:  PORTA_ADMIN=9101 bun run s3:tunel"
    exit 1
  fi
done

# As credenciais moram no .env da VPS, modo 600, e nunca neste repositório.
CREDS=$(ssh "$VPS" 'grep -E "^S3_ADMIN_(USER|PASSWORD)=" /opt/s3/.env')
USUARIO=$(printf '%s\n' "$CREDS" | sed -n 's/^S3_ADMIN_USER=//p')
SENHA=$(printf '%s\n' "$CREDS"   | sed -n 's/^S3_ADMIN_PASSWORD=//p')

URL="http://127.0.0.1:$PORTA_ADMIN"

echo
negrito "  Painel do S3"
echo
echo "    $URL"
echo
echo "    usuário  $USUARIO"
echo "    senha    $SENHA"
echo
cinza "    API S3 nesta máquina: http://127.0.0.1:$PORTA_API"
cinza "    Ctrl-C fecha o túnel."
echo

# Abre o navegador se houver como. wslview cobre o WSL, onde xdg-open não
# alcança o Windows. Falhar aqui não é motivo para derrubar o túnel.
for abridor in wslview xdg-open open; do
  if command -v "$abridor" >/dev/null 2>&1; then
    ( sleep 2; "$abridor" "$URL" >/dev/null 2>&1 || true ) &
    break
  fi
done

# -N: não executa comando remoto, só encaminha portas.
# ExitOnForwardFailure: se a porta não puder ser aberta, morre agora com erro,
# em vez de ficar um túnel de pé que não encaminha nada.
exec ssh -N \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -L "127.0.0.1:$PORTA_ADMIN:127.0.0.1:9001" \
  -L "127.0.0.1:$PORTA_API:127.0.0.1:9000" \
  "$VPS"
