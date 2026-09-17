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

printf '[rerun] configurando worker para execução batch não interativa...\n'
ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$DOM1_SSH_TARGET" \
  "sudo -n incus exec '$CONTAINER_NAME' -- runuser -u slave -- python3 - '$REMOTE_REPO/scripts/slave_worker.py'" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text(encoding='utf-8')
s = s.replace('llama_cli = LLAMA_BIN / "llama-cli"', 'llama_cli = LLAMA_BIN / "llama-completion"')
s = s.replace('llama-cli nao encontrado', 'llama-completion nao encontrado')
s = s.replace('llama-cli terminou com codigo', 'llama-completion terminou com codigo')
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

printf '[rerun] executando benchmark batch com timeout por nível...\n'
exec bash "$ROOT/diagnostics/benchmark-ladder.sh" "$@"
