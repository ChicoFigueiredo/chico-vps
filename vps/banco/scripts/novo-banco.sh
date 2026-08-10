#!/usr/bin/env bash
# Cria um database + role isolados para um projeto.
#
#   /opt/banco/scripts/novo-banco.sh meuprojeto
#   /opt/banco/scripts/novo-banco.sh meuprojeto vector pg_trgm
#
# Extensões passadas como argumentos extras são criadas AQUI, como superusuário —
# o role do projeto não tem poder para isso (pgvector e afins não são "trusted
# extensions", então CREATE EXTENSION exige superusuário).
#
# O role criado só enxerga o próprio database: o CONNECT do PUBLIC é revogado,
# então nenhum projeto alcança o banco de outro nem por engano.
# A credencial fica em /opt/banco/credenciais/<nome>.env (modo 600).
set -euo pipefail

NOME="${1:-}"
[[ -n "$NOME" ]] || { echo "uso: $0 <nome-do-banco> [extensao...]" >&2; exit 1; }
shift || true
EXTENSOES=("$@")

# Postgres dobra identificador não-citado para minúsculo e não aceita hífen sem
# aspas. Exigir o formato certo aqui evita um erro obscuro lá na frente.
[[ "$NOME" =~ ^[a-z][a-z0-9_]{1,62}$ ]] || {
  echo "nome inválido: use minúsculas, dígitos e _, começando por letra (ex: focus_scrap)" >&2
  exit 1
}

psql() { docker exec -i banco psql -U postgres -v ON_ERROR_STOP=1 "$@"; }

if psql -tAc "select 1 from pg_database where datname='$NOME'" | grep -q 1; then
  echo "banco '$NOME' já existe — nada feito." >&2
  echo "credencial: /opt/banco/credenciais/$NOME.env" >&2
  exit 0
fi

SENHA=$(openssl rand -base64 30 | tr -d '/+=' | head -c 32)

psql <<SQL
CREATE ROLE "$NOME" WITH LOGIN PASSWORD '$SENHA';
CREATE DATABASE "$NOME" OWNER "$NOME";
-- Sem isto, qualquer role do servidor consegue se conectar neste banco.
REVOKE CONNECT ON DATABASE "$NOME" FROM PUBLIC;
GRANT CONNECT ON DATABASE "$NOME" TO "$NOME";
SQL

# O schema public pertence ao dono do banco a partir do PG15, mas deixamos
# explícito para não depender da versão.
psql -d "$NOME" <<SQL
ALTER SCHEMA public OWNER TO "$NOME";
SQL

# Extensões, como superusuário. O dono do banco não consegue criá-las sozinho.
for ext in "${EXTENSOES[@]}"; do
  if psql -tAc "select 1 from pg_available_extensions where name='$ext'" | grep -q 1; then
    psql -d "$NOME" -c "CREATE EXTENSION IF NOT EXISTS \"$ext\";" >/dev/null
    echo "  extensão '$ext' habilitada"
  else
    echo "  aviso: extensão '$ext' não existe nesta imagem — ignorada" >&2
  fi
done

CRED="/opt/banco/credenciais/$NOME.env"
cat > "$CRED" <<VARS
# Banco '$NOME' — criado em $(date -Iseconds)
# De dentro de um container (precisa estar na rede 'rede-banco'):
DATABASE_URL=postgresql://$NOME:$SENHA@banco:5432/$NOME
# Da própria VPS, ou pela ponta de um túnel SSH:
DATABASE_URL_LOCAL=postgresql://$NOME:$SENHA@127.0.0.1:5432/$NOME
VARS
chmod 600 "$CRED"

cat <<FIM

  Banco '$NOME' criado.

  Credencial salva em: $CRED
  (guarde a senha no BitWarden — este arquivo não vai para o git)

  De um container na VPS — junte-o à rede 'rede-banco':

      services:
        seu-app:
          networks: [sua-rede, rede-banco]
      networks:
        rede-banco:
          external: true

      DATABASE_URL=postgresql://$NOME:***@banco:5432/$NOME

  Da sua máquina, por túnel SSH:

      ssh -N -L 5432:127.0.0.1:5432 root@ssh.chico-figueiredo.com.br
      DATABASE_URL=postgresql://$NOME:***@127.0.0.1:5432/$NOME

FIM
