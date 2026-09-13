#!/usr/bin/env bash
set -Eeuo pipefail

# Execute no devel3 para ligar o Codex ao MCP dentro do container Incus no Dom1.
# O transporte e MCP/stdio encapsulado em SSH; nenhuma porta MCP e publicada.
#
# Variaveis opcionais:
#   DOM1_SSH_TARGET=esteban@dom1.inovacaosistemas.com.br
#   CONTAINER_NAME=alt-claude-slave
#   REMOTE_MCP=/srv/alt-claude/repos/alt-claude-slave/scripts/slave_mcp.py
#   MCP_NAME=alt-claude-slave
#   INSTALL_DIR=/home/esteban/.local/bin

readonly DOM1_SSH_TARGET="${DOM1_SSH_TARGET:-esteban@dom1.inovacaosistemas.com.br}"
readonly CONTAINER_NAME="${CONTAINER_NAME:-alt-claude-slave}"
readonly REMOTE_MCP="${REMOTE_MCP:-/srv/alt-claude/repos/alt-claude-slave/scripts/slave_mcp.py}"
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
command -v python3 >/dev/null 2>&1 || die "Python 3 nao encontrado no devel3."
command -v timeout >/dev/null 2>&1 || die "Comando timeout nao encontrado no devel3."

log "Testando SSH ate $DOM1_SSH_TARGET"
ssh -T \
  -o BatchMode=yes \
  -o ConnectTimeout=10 \
  "$DOM1_SSH_TARGET" \
  "sudo -n incus info '$CONTAINER_NAME' >/dev/null" \
  || die "SSH funcionou, mas sudo -n incus nao conseguiu acessar o container $CONTAINER_NAME no Dom1."

log "Verificando o servidor MCP como usuario slave"
if ! ssh -T \
  -o BatchMode=yes \
  -o ConnectTimeout=10 \
  "$DOM1_SSH_TARGET" \
  "sudo -n incus exec '$CONTAINER_NAME' -- runuser -u slave -- test -r '$REMOTE_MCP'"; then
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

readonly LOG_DIR="\${XDG_STATE_HOME:-\${HOME}/.local/state}/alt-claude-slave"
install -d -m 0700 "\$LOG_DIR"

exec ssh -T \\
  -o LogLevel=ERROR \\
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
    -- runuser -u slave -- python3 '$REMOTE_MCP'" \\
  2> >(tee -a "\$LOG_DIR/mcp-stderr.log" >&2)
EOF

install -m 0755 "$temporary_bridge" "$BRIDGE_PATH"

log "Validando handshake MCP de ponta a ponta"
probe_stdout="$(mktemp)"
probe_stderr="$(mktemp)"
trap 'rm -f "$temporary_bridge" "$probe_stdout" "$probe_stderr"' EXIT

if ! printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"alt-claude-slave-setup","version":"1"}}}' \
  | timeout 20 "$BRIDGE_PATH" >"$probe_stdout" 2>"$probe_stderr"; then
  printf 'O servidor MCP encerrou durante o handshake. Erro:\n' >&2
  sed -n '1,80p' "$probe_stderr" >&2
  exit 4
fi

if ! python3 - "$probe_stdout" <<'PY'
import json
import sys

path = sys.argv[1]
lines = [line for line in open(path, encoding="utf-8") if line.strip()]
if len(lines) != 1:
    raise SystemExit(f"stdout MCP invalido: esperada 1 linha JSON, recebidas {len(lines)}")
message = json.loads(lines[0])
if message.get("id") != 1 or message.get("result", {}).get("serverInfo", {}).get("name") != "alt-claude-slave":
    raise SystemExit(f"resposta initialize inesperada: {message!r}")
PY
then
  printf 'Resposta recebida do MCP:\n' >&2
  sed -n '1,20p' "$probe_stdout" >&2
  printf 'Erros recebidos pelo bridge:\n' >&2
  sed -n '1,80p' "$probe_stderr" >&2
  exit 5
fi

if codex mcp list 2>/dev/null | awk '{print $1}' | grep -Fxq "$MCP_NAME"; then
  log "Removendo registro MCP anterior"
  codex mcp remove "$MCP_NAME"
fi

log "Registrando o MCP no Codex"
codex mcp add "$MCP_NAME" -- "$BRIDGE_PATH"

log "Configuracao concluida"
codex mcp list
printf '\nAbra uma nova sessao do Codex e confira com /mcp.\n'
