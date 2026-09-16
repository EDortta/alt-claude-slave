#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT_DIR="$ROOT/diagnostics/reports/$STAMP"
DOM1_SSH_TARGET="${DOM1_SSH_TARGET:-esteban@dom1.inovacaosistemas.com.br}"
CONTAINER_NAME="${CONTAINER_NAME:-alt-claude-slave}"
REMOTE_REPO="${REMOTE_REPO:-/srv/alt-claude/repos/alt-claude-slave}"
MCP_NAME="${MCP_NAME:-alt-claude-slave}"
BRIDGE="${ALT_CLAUDE_SLAVE_MCP:-$HOME/.local/bin/alt-claude-slave-mcp}"
mkdir -p "$REPORT_DIR"

CURRENT_STEP="startup"
trap 'rc=$?; printf "\n[diagnóstico] interrompido em: %s (exit=%s)\n[diagnóstico] relatório parcial: %s\n" "$CURRENT_STEP" "$rc" "$REPORT_DIR" >&2' ERR

say() {
  printf '[diagnóstico] %s\n' "$*"
}

run() {
  local name="$1"; shift
  CURRENT_STEP="$name"
  say "$name ..."
  local rc=0
  {
    echo "+ $*"
    "$@" || rc=$?
    echo
    echo "exit=$rc"
  } >"$REPORT_DIR/$name.txt" 2>&1
  if (( rc == 0 )); then
    say "$name: OK"
  else
    say "$name: FALHOU (exit=$rc) — registrado em $name.txt"
  fi
  return 0
}

run_shell() {
  local name="$1" command="$2"
  CURRENT_STEP="$name"
  say "$name ..."
  local rc=0
  {
    echo "+ $command"
    bash -lc "$command" || rc=$?
    echo
    echo "exit=$rc"
  } >"$REPORT_DIR/$name.txt" 2>&1
  if (( rc == 0 )); then
    say "$name: OK"
  else
    say "$name: FALHOU (exit=$rc) — registrado em $name.txt"
  fi
  return 0
}

say "iniciando"
say "relatório: $REPORT_DIR"
say "Dom1: $DOM1_SSH_TARGET"
say "container: $CONTAINER_NAME"
say "bridge: $BRIDGE"

cat >"$REPORT_DIR/00-context.txt" <<EOF
captured_at=$(date -Is)
host=$(hostname -f 2>/dev/null || hostname)
user=$(id -un)
repo=$ROOT
dom1=$DOM1_SSH_TARGET
container=$CONTAINER_NAME
remote_repo=$REMOTE_REPO
bridge=$BRIDGE
mcp_name=$MCP_NAME
EOF

run_shell 01-local-versions 'uname -a; echo; command -v codex || true; codex --version 2>&1 || true; echo; command -v ssh || true; ssh -V 2>&1 || true; echo; python3 --version; echo; git --version'
run_shell 02-repo-state "cd '$ROOT' && git status --short --branch && echo && git log -5 --oneline --decorate"
run_shell 03-codex-mcp "codex mcp list 2>&1 || true; echo; codex mcp get '$MCP_NAME' 2>&1 || true"
run_shell 04-bridge "ls -lah '$BRIDGE' 2>&1 || true; echo; file '$BRIDGE' 2>&1 || true; echo; sed -n '1,220p' '$BRIDGE' 2>/dev/null | sed -E 's/(token|key|secret|authorization)([^= :]*)([=: ]+).*/\\1\\2\\3<redacted>/Ig' || true"
run_shell 05-ssh "ssh -T -o BatchMode=yes -o ConnectTimeout=10 '$DOM1_SSH_TARGET' 'hostname; id; sudo -n incus info \"$CONTAINER_NAME\"'"
run_shell 06-dom1-incus "ssh -T -o BatchMode=yes -o ConnectTimeout=10 '$DOM1_SSH_TARGET' 'echo HOST:; uname -a; echo; command -v incus; incus --version; echo; sudo -n incus list; echo; sudo -n incus info \"$CONTAINER_NAME\"'"
run_shell 07-container "ssh -T -o BatchMode=yes -o ConnectTimeout=10 '$DOM1_SSH_TARGET' 'sudo -n incus exec \"$CONTAINER_NAME\" -- bash -lc '\''id; uname -a; python3 --version; git --version; echo; ls -lah \"$REMOTE_REPO\"; echo; cd \"$REMOTE_REPO\" && git status --short --branch && git log -3 --oneline --decorate; echo; ls -lah scripts/slave_mcp.py slave-mcp 2>&1 || true'\'''"
run_shell 08-container-tests "ssh -T -o BatchMode=yes -o ConnectTimeout=10 '$DOM1_SSH_TARGET' 'sudo -n incus exec \"$CONTAINER_NAME\" -- bash -lc '\''cd \"$REMOTE_REPO\" && bash tests/run.sh'\'''"

INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"alt-claude-diagnostics","version":"1"}}}'
TOOLS='{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'

CURRENT_STEP="09-bridge-initialize"
say "09-bridge-initialize ..."
rc=0
{
  echo "+ initialize via local bridge"
  if [[ -x "$BRIDGE" ]]; then
    printf '%s\n' "$INIT" | timeout 25 "$BRIDGE" || rc=$?
  else
    echo "bridge_not_executable"
    rc=127
  fi
  echo
  echo "exit=$rc"
} >"$REPORT_DIR/09-bridge-initialize.txt" 2>&1
if (( rc == 0 )); then say "09-bridge-initialize: OK"; else say "09-bridge-initialize: FALHOU (exit=$rc)"; fi

CURRENT_STEP="10-bridge-tools-list"
say "10-bridge-tools-list ..."
rc=0
{
  echo "+ initialize + tools/list via local bridge"
  if [[ -x "$BRIDGE" ]]; then
    { printf '%s\n' "$INIT"; printf '%s\n' "$TOOLS"; } | timeout 25 "$BRIDGE" || rc=$?
  else
    echo "bridge_not_executable"
    rc=127
  fi
  echo
  echo "exit=$rc"
} >"$REPORT_DIR/10-bridge-tools-list.txt" 2>&1
if (( rc == 0 )); then say "10-bridge-tools-list: OK"; else say "10-bridge-tools-list: FALHOU (exit=$rc)"; fi

run_shell 11-mcp-stderr "tail -n 200 '${XDG_STATE_HOME:-$HOME/.local/state}/alt-claude-slave/mcp-stderr.log' 2>&1 || true"

cat >"$REPORT_DIR/README.txt" <<EOF
Este diretório foi gerado por diagnostics/run-all.sh.
Não deve conter conteúdo de API keys/tokens; ainda assim revise antes de commit/push.
Arquivos mais importantes para diagnóstico MCP:
  03-codex-mcp.txt
  04-bridge.txt
  05-ssh.txt
  07-container.txt
  08-container-tests.txt
  09-bridge-initialize.txt
  10-bridge-tools-list.txt
  11-mcp-stderr.txt
EOF

CURRENT_STEP="done"
printf '\n[diagnóstico] CONCLUÍDO\n'
printf '[diagnóstico] relatório: %s\n' "$REPORT_DIR"
printf '[diagnóstico] próximo passo:\n'
printf '  bash diagnostics/publish-report.sh %q\n' "$REPORT_DIR"
