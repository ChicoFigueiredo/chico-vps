#!/usr/bin/env bash
# Cria a identidade raiz do servidor de objetos.
#
#   /opt/s3/scripts/bootstrap.sh
#
# ⚠ Este passo NÃO é opcional, e é o mais importante da instalação.
#
# Sem nenhuma identidade configurada, o gateway S3 do SeaweedFS aceita tudo
# anonimamente: qualquer um que alcance a porta cria bucket, grava e lê, sem
# credencial nenhuma. Foi verificado com curl, e devolveu HTTP 200 nas três
# operações. Assim que a primeira identidade existe, o anônimo passa a levar 403.
#
# É a mesma classe de falha do phpMyAdmin aberto que custou o banco do basilio
# em julho de 2026.
#
# Idempotente: se a raiz já existe, não faz nada.
set -euo pipefail

# shellcheck disable=SC1091
. /opt/s3/.env

: "${S3_ROOT_ACCESS_KEY:?defina em /opt/s3/.env}"
: "${S3_ROOT_SECRET_KEY:?defina em /opt/s3/.env}"

if docker exec s3 sh -c "echo 's3.user.list' | weed shell -master=s3:9333" 2>/dev/null \
   | grep -q "\"name\":\"$S3_ROOT_ACCESS_KEY\""; then
  echo "identidade raiz já existe — nada feito."
  exit 0
fi

# s3:* sobre todos os buckets. É a credencial usada pelos scripts de backup e
# de administração — nunca por uma aplicação, que recebe a sua pelo novo-s3.sh.
POLITICA='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:*"],"Resource":["arn:aws:s3:::*","arn:aws:s3:::*/*"]}]}'

printf '%s' "$POLITICA" | docker exec -i s3 sh -c 'cat > /tmp/raiz.json'

docker exec s3 sh -c "printf '%s\n' \
  's3.policy -put -name=raiz-total -file=/tmp/raiz.json' \
  's3.user.create -name $S3_ROOT_ACCESS_KEY -access_key $S3_ROOT_ACCESS_KEY -secret_key $S3_ROOT_SECRET_KEY' \
  's3.policy.attach -policy raiz-total -user $S3_ROOT_ACCESS_KEY' \
  | weed shell -master=s3:9333" >/dev/null

docker exec s3 rm -f /tmp/raiz.json

# Prova que fechou, em vez de presumir.
CODIGO=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9000/)
if [ "$CODIGO" = "403" ]; then
  echo "identidade raiz criada — acesso anônimo agora devolve 403."
else
  echo "ATENÇÃO: acesso anônimo devolveu HTTP $CODIGO, esperado 403." >&2
  exit 1
fi
