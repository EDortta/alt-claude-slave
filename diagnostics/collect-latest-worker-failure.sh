#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOM1_SSH_TARGET="${DOM1_SSH_TARGET:-esteban@dom1.inovacaosistemas.com.br}"
CONTAINER_NAME="${CONTAINER_NAME:-alt-claude-slave}"
REPORT_DIR="${1:-}"

if [[ -z "$REPORT_DIR" ]]; then
  REPORT_DIR="$(find "$ROOT/diagnostics/reports" -maxdepth 1 -mindepth 1 -type d -name '*-worker' | sort | tail -n 1)"
fi

[[ -n "$REPORT_DIR" && -d "$REPORT_DIR" ]] || { echo "Relatório worker não encontrado" >&2; exit 2; }
[[ -f "$REPORT_DIR/task-id.txt" ]] || { echo "task-id.txt não encontrado em $REPORT_DIR" >&2; exit 2; }

TASK_ID="$(tr -d '\r\n' < "$REPORT_DIR/task-id.txt")"
[[ "$TASK_ID" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$ ]] || { echo "task id inválido: $TASK_ID" >&2; exit 2; }

printf '[collector] relatório: %s\n' "$REPORT_DIR"
printf '[collector] task_id: %s\n' "$TASK_ID"

remote() {
  ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$DOM1_SSH_TARGET" \
    "sudo -n incus exec '$CONTAINER_NAME' -- runuser -u slave -- bash -lc '$1'"
}

printf '[collector] coletando saída bruta do llama-cli...\n'
remote "cat '/srv/alt-claude/state/tasks/$TASK_ID.model-output.txt' 2>&1 || true" \
  >"$REPORT_DIR/11-model-output.txt" 2>&1 || true

printf '[collector] coletando prompt usado pelo worker...\n'
remote "sed -n '1,260p' '/srv/alt-claude/state/tasks/$TASK_ID.prompt' 2>&1 || true" \
  >"$REPORT_DIR/12-prompt.txt" 2>&1 || true

printf '[collector] coletando versão/opções do llama.cpp...\n'
remote "'/home/slave/.local/opt/llama.cpp/bin/llama-cli' --version 2>&1; echo; '/home/slave/.local/opt/llama.cpp/bin/llama-cli' --help 2>&1 | grep -E -A3 -B2 -- '-hf|--hf-repo|hugging|model' | head -n 160" \
  >"$REPORT_DIR/13-llama-info.txt" 2>&1 || true

printf '[collector] coletando cache do modelo...\n'
remote "find /srv/alt-claude/models /home/slave/.cache -maxdepth 5 -type f 2>/dev/null | sed -n '1,200p'" \
  >"$REPORT_DIR/14-model-cache.txt" 2>&1 || true

printf '[collector] concluído. Publique o mesmo diretório:\n'
printf '  bash diagnostics/publish-report.sh %q\n' "$REPORT_DIR"
