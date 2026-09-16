#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOM1_SSH_TARGET="${DOM1_SSH_TARGET:-esteban@dom1.inovacaosistemas.com.br}"
CONTAINER_NAME="${CONTAINER_NAME:-alt-claude-slave}"
REMOTE_REPO="${REMOTE_REPO:-/srv/alt-claude/repos/alt-claude-slave}"
BRANCH="${ALT_CLAUDE_SLAVE_BRANCH:-diagnostics/mcp-end-to-end}"
export SLAVE_ACCEPTANCE_REPO="${SLAVE_ACCEPTANCE_REPO:-alt-claude-slave-acceptance}"

printf '[rerun] sincronizando código no container...\n'
ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$DOM1_SSH_TARGET" \
  "sudo -n incus exec '$CONTAINER_NAME' -- runuser -u slave -- bash -lc 'cd \"$REMOTE_REPO\" && git fetch origin && git checkout \"$BRANCH\" && git reset --hard \"origin/$BRANCH\"'"

printf '[rerun] aplicando compatibilidade do llama-cli instalado...\n'
ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$DOM1_SSH_TARGET" \
  "sudo -n incus exec '$CONTAINER_NAME' -- runuser -u slave -- python3 - '$REMOTE_REPO/scripts/slave_worker.py'" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text(encoding='utf-8')
for line in (
    '                "--conversation",\n',
    '                "--single-turn",\n',
    '                "--jinja",\n',
    '                "--no-display-prompt",\n',
):
    s = s.replace(line, '')
p.write_text(s, encoding='utf-8')
PY

printf '[rerun] executando teste de aceitação...\n'
exec bash "$ROOT/diagnostics/verify-mcp-worker.sh" "$@"
