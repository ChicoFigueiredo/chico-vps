#!/usr/bin/env bash
# Constantes e utilidades compartilhadas pelos scripts do repositório.
# Não roda sozinho: é carregado com '.' pelos outros.

VPS="${VPS:-root@ssh.chico-figueiredo.com.br}"

# Portas na SUA máquina. Mudáveis por variável de ambiente para o caso de já
# haver algo escutando nelas aqui.
PORTA_ADMIN="${PORTA_ADMIN:-9001}"
PORTA_API="${PORTA_API:-9000}"

vermelho() { printf '\033[31m%s\033[0m\n' "$*"; }
verde()    { printf '\033[32m%s\033[0m\n' "$*"; }
cinza()    { printf '\033[90m%s\033[0m\n' "$*"; }
negrito()  { printf '\033[1m%s\033[0m\n' "$*"; }

# Falha cedo e com uma mensagem útil, em vez de deixar o erro aparecer lá na
# frente disfarçado de outra coisa.
exige_vps() {
  if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "$VPS" true 2>/dev/null; then
    vermelho "não consegui abrir SSH em $VPS"
    cinza "  verifique a rede, ou se a sua chave ainda está no authorized_keys de lá"
    exit 1
  fi
}

porta_ocupada() {
  # -sTCP:LISTEN evita contar conexões de saída para a mesma porta.
  lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
}
