#!/usr/bin/env bash
set -Eeuo pipefail

DOM1_SSH_TARGET="${DOM1_SSH_TARGET:-esteban@dom1.inovacaosistemas.com.br}"
CONTAINER_NAME="${CONTAINER_NAME:-alt-claude-slave}"
INTERVAL="${SLAVE_WATCH_INTERVAL:-2}"

ssh -t "$DOM1_SSH_TARGET" \
  "sudo -n incus exec '$CONTAINER_NAME' -- bash -s -- '$INTERVAL'" <<'REMOTE'
set -Eeuo pipefail
INTERVAL="${1:-2}"

while true; do
  clear 2>/dev/null || printf '\033[2J\033[H'
  echo '=== alt-claude-slave / T610 ==='
  date -Is
  echo
  echo '--- processos ---'
  processes="$(ps -eo pid,etime,%cpu,%mem,rss,cmd --sort=-%cpu | grep -E '[s]lave_worker.py|[l]lama-(completion|cli|server)' | head -n 12 || true)"
  if [[ -n "$processes" ]]; then
    printf '%s\n' "$processes"
  else
    echo 'nenhum processo ativo'
  fi

  echo
  echo '--- tarefa mais recente ---'
  latest="$(ls -1t /srv/alt-claude/state/tasks/*.json 2>/dev/null | head -n1 || true)"
  if [[ -n "$latest" ]]; then
    python3 - "$latest" <<'PY'
import json, sys
p = sys.argv[1]
try:
    with open(p, encoding='utf-8') as fh:
        d = json.load(fh)
except Exception as exc:
    print(p, exc)
    raise SystemExit
for k in ('task_id','status','repository','model','pid','created_at','started_at','updated_at','finished_at','error'):
    if k in d:
        print(f'{k}: {d[k]}')
PY

    echo
    log="${latest%.json}.log"
    echo "--- tail $log ---"
    tail -n 20 "$log" 2>/dev/null || true

    out="${latest%.json}.model-output.txt"
    if [[ -f "$out" ]]; then
      echo
      echo '--- model output (últimas linhas) ---'
      tail -n 12 "$out" 2>/dev/null || true
    fi
  else
    echo 'nenhuma tarefa encontrada'
  fi

  sleep "$INTERVAL"
done
REMOTE
