#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOM1_SSH_TARGET="${DOM1_SSH_TARGET:-esteban@dom1.inovacaosistemas.com.br}"
CONTAINER_NAME="${CONTAINER_NAME:-alt-claude-slave}"
REMOTE_REPO="${REMOTE_REPO:-/srv/alt-claude/repos/alt-claude-slave}"
BRANCH="${ALT_CLAUDE_SLAVE_BRANCH:-diagnostics/mcp-end-to-end}"
export SLAVE_ACCEPTANCE_REPO="${SLAVE_ACCEPTANCE_REPO:-alt-claude-slave-acceptance}"
export SLAVE_ACCEPTANCE_TIMEOUT="${SLAVE_ACCEPTANCE_TIMEOUT:-900}"

printf '[rerun] limpando tarefas antigas de aceitação...\n'
ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$DOM1_SSH_TARGET" \
  "sudo -n incus exec '$CONTAINER_NAME' -- runuser -u slave -- python3 - '$SLAVE_ACCEPTANCE_REPO'" <<'PY'
import json, os, signal, sys
from pathlib import Path
repo = sys.argv[1]
tasks = Path('/srv/alt-claude/state/tasks')
for path in tasks.glob('*.json'):
    try:
        task = json.loads(path.read_text(encoding='utf-8'))
    except Exception:
        continue
    if task.get('repository') != repo or task.get('status') not in {'queued','running'}:
        continue
    pid = task.get('pid')
    if isinstance(pid, int) and pid > 1:
        try:
            cmd = Path(f'/proc/{pid}/cmdline').read_bytes().replace(b'\0', b' ').decode(errors='replace')
            if 'slave_worker.py' in cmd and task.get('task_id','') in cmd:
                os.killpg(pid, signal.SIGTERM)
        except (FileNotFoundError, ProcessLookupError):
            pass
    task['status'] = 'canceled'
    task['error'] = 'canceled by acceptance rerun cleanup'
    path.write_text(json.dumps(task, ensure_ascii=False, indent=2, sort_keys=True) + '\n', encoding='utf-8')
PY

printf '[rerun] sincronizando código no container...\n'
ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$DOM1_SSH_TARGET" \
  "sudo -n incus exec '$CONTAINER_NAME' -- runuser -u slave -- bash -lc 'cd \"$REMOTE_REPO\" && git fetch origin && git checkout \"$BRANCH\" && git reset --hard \"origin/$BRANCH\"'"

printf '[rerun] aplicando compatibilidade e limite de geração do llama-cli...\n'
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
s = s.replace('                "-n", "3072",\n', '                "-n", "512",\n')
p.write_text(s, encoding='utf-8')
PY

printf '[rerun] executando teste de aceitação...\n'
exec bash "$ROOT/diagnostics/verify-mcp-worker.sh" "$@"
