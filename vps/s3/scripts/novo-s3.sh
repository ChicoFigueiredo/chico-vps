#!/usr/bin/env bash
# Cria um bucket + credencial isolados para um projeto.
#
#   /opt/s3/scripts/novo-s3.sh meuprojeto
#   /opt/s3/scripts/novo-s3.sh meuprojeto somente-leitura
#
# O usuário criado só enxerga o próprio bucket: a política anexada nomeia o
# bucket explicitamente, então nenhum projeto alcança os arquivos de outro nem
# por engano. Mesma ideia do novo-banco.sh, com política em vez de GRANT.
#
# A credencial fica em /opt/s3/credenciais/<nome>.env (modo 600).
set -euo pipefail

NOME="${1:-}"
PAPEL="${2:-leitura-escrita}"
[[ -n "$NOME" ]] || { echo "uso: $0 <nome-do-projeto> [leitura-escrita|somente-leitura]" >&2; exit 1; }

# Regra de nome de bucket da AWS, e o SeaweedFS segue a mesma: minúsculas,
# dígitos e hífen, de 3 a 63 caracteres. Underline NÃO vale — diferente do
# Postgres, onde é o separador natural. 'focus_scrap' aqui vira 'focus-scrap'.
[[ "$NOME" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]] || {
  echo "nome inválido: minúsculas, dígitos e hífen, de 3 a 63 caracteres" >&2
  echo "  (underline não é aceito em nome de bucket — use hífen)" >&2
  exit 1
}

# Sem 's3:CreateBucket', e por dois motivos. O primeiro é que quem cria bucket
# aqui é este script. O segundo é que não adiantaria: o SeaweedFS trata criação
# de bucket como privilégio global e nega mesmo com o ARN do próprio bucket na
# política — testado.
#
# A consequência aparece no rclone, que chama CreateBucket antes do primeiro
# upload só para garantir que o destino existe. O upload falha com
# "AccessDenied: CreateBucket", que parece falta de permissão de escrita.
# A solução no cliente é --s3-no-check-bucket. Os SDKs da AWS não fazem essa
# chamada, então aplicação nenhuma sente isso — só ferramenta de linha de comando.
case "$PAPEL" in
  leitura-escrita) ACOES='"s3:GetObject","s3:PutObject","s3:DeleteObject","s3:ListBucket","s3:AbortMultipartUpload","s3:ListBucketMultipartUploads","s3:ListMultipartUploadParts"' ;;
  somente-leitura) ACOES='"s3:GetObject","s3:ListBucket"' ;;
  *) echo "papel inválido: use 'leitura-escrita' ou 'somente-leitura'" >&2; exit 1 ;;
esac

# O s3.user.list devolve um array JSON numa linha só, não um nome por linha —
# daí a busca pelo campo em vez de comparar a linha inteira.
if docker exec s3 sh -c "echo 's3.user.list' | weed shell -master=s3:9333" 2>/dev/null \
   | grep -q "\"name\":\"$NOME\""; then
  echo "projeto '$NOME' já existe — nada feito." >&2
  echo "credencial: /opt/s3/credenciais/$NOME.env" >&2
  exit 0
fi

# Formato das credenciais da AWS: chave de 20 caracteres, segredo de 40.
# Vários SDKs validam o tamanho antes de assinar a requisição.
#
# 'openssl rand -hex 10' dá exatamente 20 caracteres. O caminho óbvio seria
# 'tr -dc A-Z0-9 </dev/urandom | head -c 20', mas /dev/urandom é infinito: o
# head fecha o cano, o tr morre de SIGPIPE (141) e o 'pipefail' derruba o script
# inteiro — sem mensagem, porque a variável já tinha sido atribuída.
CHAVE="$(openssl rand -hex 10 | tr 'a-f' 'A-F')"
SEGREDO="$(openssl rand -base64 48 | tr -d '/+=' | head -c 40)"

# ListBucket age sobre o bucket; as demais, sobre os objetos dentro dele.
# São dois ARNs diferentes — com um só, ou o list falha ou o get falha.
POLITICA=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [$ACOES],
      "Resource": [
        "arn:aws:s3:::$NOME",
        "arn:aws:s3:::$NOME/*"
      ]
    }
  ]
}
JSON
)

printf '%s' "$POLITICA" | docker exec -i s3 sh -c "cat > /tmp/politica-$NOME.json"

docker exec s3 sh -c "printf '%s\n' \
  's3.bucket.create -name $NOME' \
  's3.policy -put -name=$NOME -file=/tmp/politica-$NOME.json' \
  's3.user.create -name $NOME -access_key $CHAVE -secret_key $SEGREDO' \
  's3.policy.attach -policy $NOME -user $NOME' \
  | weed shell -master=s3:9333" >/dev/null

docker exec s3 rm -f "/tmp/politica-$NOME.json"

CRED="/opt/s3/credenciais/$NOME.env"
cat > "$CRED" <<VARS
# Bucket '$NOME' ($PAPEL) — criado em $(date -Iseconds)
S3_BUCKET=$NOME
S3_ACCESS_KEY_ID=$CHAVE
S3_SECRET_ACCESS_KEY=$SEGREDO
# De dentro de um container (precisa estar na rede 'rede-s3'):
S3_ENDPOINT=http://s3:8333
# Da própria VPS, ou pela ponta de um túnel SSH:
S3_ENDPOINT_LOCAL=http://127.0.0.1:9000
# O SDK da AWS exige uma região mesmo quando o servidor não usa nenhuma.
S3_REGION=us-east-1
# Obrigatório: sem isto o SDK monta 'http://$NOME.s3:8333' e não resolve.
S3_FORCE_PATH_STYLE=true
VARS
chmod 600 "$CRED"

cat <<FIM

  Bucket '$NOME' criado ($PAPEL).

  Credencial salva em: $CRED
  (guarde no BitWarden — este arquivo não vai para o git)

  De um container na VPS — junte-o à rede 'rede-s3':

      services:
        seu-app:
          networks: [sua-rede, rede-s3]
      networks:
        rede-s3:
          external: true

  No código, é a AWS normal — só o endpoint muda:

      import { S3Client } from "@aws-sdk/client-s3";

      const s3 = new S3Client({
        endpoint: process.env.S3_ENDPOINT,
        region: process.env.S3_REGION,
        forcePathStyle: true,          // sem isto, nada funciona
        credentials: {
          accessKeyId:     process.env.S3_ACCESS_KEY_ID,
          secretAccessKey: process.env.S3_SECRET_ACCESS_KEY,
        },
      });

  Da sua máquina, por túnel SSH:

      bun run s3:tunel
      # e então S3_ENDPOINT=http://127.0.0.1:9000

FIM
