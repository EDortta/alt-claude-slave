#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOM1_SSH_TARGET="${DOM1_SSH_TARGET:-esteban@dom1.inovacaosistemas.com.br}"
CONTAINER_NAME="${CONTAINER_NAME:-alt-claude-slave}"
REMOTE_REPO="${REMOTE_REPO:-/srv/alt-claude/repos/alt-claude-slave}"
BRANCH="${ALT_CLAUDE_SLAVE_BRANCH:-diagnostics/mcp-end-to-end}"

printf '[rerun] limpando apenas tarefas antigas de diagnóstico...\n'
ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$DOM1_SSH_TARGET" \
  "sudo -n incus exec '$CONTAINER_NAME' -- runuser -u slave -- python3 -" <<'PY'
import json, os, signal
from datetime import datetime, timezone
from pathlib import Path

tasks = Path('/srv/alt-claude/state/tasks')
for path in tasks.glob('*.json'):
    try:
        task = json.loads(path.read_text(encoding='utf-8'))
    except Exception:
        continue
    repo = str(task.get('repository',''))
    if not (repo == 'alt-claude-slave-acceptance' or repo.startswith('alt-claude-bench-')):
        continue
    if task.get('status') not in {'queued','running'}:
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
    task['error'] = 'canceled by diagnostic rerun cleanup'
    task['updated_at'] = datetime.now(timezone.utc).isoformat()
    path.write_text(json.dumps(task, ensure_ascii=False, indent=2, sort_keys=True) + '\n', encoding='utf-8')
PY

printf '[rerun] sincronizando código no container...\n'
ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$DOM1_SSH_TARGET" \
  "sudo -n incus exec '$CONTAINER_NAME' -- runuser -u slave -- bash -lc 'cd \"$REMOTE_REPO\" && git fetch origin && git checkout \"$BRANCH\" && git reset --hard \"origin/$BRANCH\"'"

printf '[rerun] garantindo runner batch llama-completion...\n'
ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$DOM1_SSH_TARGET" \
  "sudo -n incus exec '$CONTAINER_NAME' -- runuser -u slave -- bash -lc '
    set -e
    BIN=/home/slave/.local/opt/llama.cpp/bin
    SRC=/home/slave/.local/src/llama.cpp
    if [ ! -x \"\$BIN/llama-completion\" ]; then
      echo \"[rerun/remote] compilando llama-completion...\"
      cmake --build \"\$SRC/build\" --target llama-completion -j \"\$(nproc)\"
      install -m 0755 \"\$SRC/build/bin/llama-completion\" \"\$BIN/llama-completion\"
    fi
    \"\$BIN/llama-completion\" --version
  '"

printf '[rerun] worker usa llama-completion + ChatML + -no-cnv permanentemente no código.\n'
printf '[rerun] executando benchmark...\n'
exec bash "$ROOT/diagnostics/benchmark-ladder.sh" "$@"
