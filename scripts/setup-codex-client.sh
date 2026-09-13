#!/usr/bin/env bash
set -Eeuo pipefail

# Execute no devel3 para ligar o Codex ao MCP dentro do container Incus no Dom1.
# O transporte e MCP/stdio encapsulado em SSH; nenhuma porta MCP e publicada.
#
# Variaveis opcionais:
#   DOM1_SSH_TARGET=esteban@dom1.inovacaosistemas.com.br
#   CONTAINER_NAME=alt-claude-slave
#   REMOTE_MCP=/srv/alt-claude/repos/alt-claude-slave/slave-mcp
#   MCP_NAME=alt-claude-slave
#   INSTALL_DIR=/home/esteban/.local/bin

readonly DOM1_SSH_TARGET="${DOM1_SSH_TARGET:-esteban@dom1.inovacaosistemas.com.br}"
readonly CONTAINER_NAME="${CONTAINER_NAME:-alt-claude-slave}"
readonly REMOTE_MCP="${REMOTE_MCP:-/srv/alt-claude/repos/alt-claude-slave/slave-mcp}"
readonly MCP_NAME="${MCP_NAME:-alt-claude-slave}"
readonly INSTALL_DIR="${INSTALL_DIR:-${HOME}/.local/bin}"
readonly BRIDGE_PATH="${INSTALL_DIR}/alt-claude-slave-mcp"

log() {
  printf '\n==> %s\n' "$*"
}

die() {
  printf 'ERRO: %s\n' "$*" >&2
  exit 1
}

command -v ssh >/dev/null 2>&1 || die "Cliente SSH nao encontrado."
command -v codex >/dev/null 2>&1 || die "Codex CLI nao encontrado no devel3."

log "Testando SSH ate $DOM1_SSH_TARGET"
ssh -T \
  -o BatchMode=yes \
  -o ConnectTimeout=10 \
  "$DOM1_SSH_TARGET" \
  "sudo -n incus info '$CONTAINER_NAME' >/dev/null" \
  || die "SSH funcionou, mas sudo -n incus nao conseguiu acessar o container $CONTAINER_NAME no Dom1."

log "Verificando o executavel MCP dentro do container"
if ! ssh -T \
  -o BatchMode=yes \
  -o ConnectTimeout=10 \
  "$DOM1_SSH_TARGET" \
  "sudo -n incus exec '$CONTAINER_NAME' -- test -x '$REMOTE_MCP'"; then
  cat >&2 <<EOF
O caminho SSH e o container estao acessiveis, mas ainda nao existe:

  $REMOTE_MCP

O alt-claude-slave atual instala llama.cpp e os benchmarks, mas ainda nao
implementa o servidor MCP. Nao registrei um servidor quebrado no Codex.
EOF
  exit 3
fi

log "Instalando bridge MCP local em $BRIDGE_PATH"
install -d -m 0755 "$INSTALL_DIR"

temporary_bridge="$(mktemp)"
trap 'rm -f "$temporary_bridge"' EXIT

cat >"$temporary_bridge" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

exec ssh -T \\
  -o BatchMode=yes \\
  -o ConnectTimeout=10 \\
  -o ServerAliveInterval=30 \\
  -o ServerAliveCountMax=3 \\
  '$DOM1_SSH_TARGET' \\
  "sudo -n incus exec '$CONTAINER_NAME' \\
    --cwd /srv/alt-claude/repos/alt-claude-slave \\
    --env HOME=/home/slave \\
    --env LLAMA_CACHE=/srv/alt-claude/models \\
    --env LLAMA_BIN=/home/slave/.local/opt/llama.cpp/bin \\
    --user 1000 --group 1000 -- '$REMOTE_MCP'"
EOF

install -m 0755 "$temporary_bridge" "$BRIDGE_PATH"

if codex mcp list 2>/dev/null | awk '{print $1}' | grep -Fxq "$MCP_NAME"; then
  log "O MCP $MCP_NAME ja esta registrado no Codex; mantendo a configuracao existente"
  printf 'Se o caminho mudou, rode:\n'
  printf '  codex mcp remove %q\n' "$MCP_NAME"
  printf '  codex mcp add %q -- %q\n' "$MCP_NAME" "$BRIDGE_PATH"
else
  log "Registrando o MCP no Codex"
  codex mcp add "$MCP_NAME" -- "$BRIDGE_PATH"
fi

log "Configuracao concluida"
codex mcp list
printf '\nAbra uma nova sessao do Codex e confira com /mcp.\n'
