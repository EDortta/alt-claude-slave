#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOM1_SSH_TARGET="${DOM1_SSH_TARGET:-esteban@dom1.inovacaosistemas.com.br}"
CONTAINER_NAME="${CONTAINER_NAME:-alt-claude-slave}"
BRIDGE="${ALT_CLAUDE_SLAVE_MCP:-$HOME/.local/bin/alt-claude-slave-mcp}"
MODEL="${SLAVE_ACCEPTANCE_MODEL:-qwen-coder-1.5b}"
TEST_REPO="${SLAVE_ACCEPTANCE_REPO:-__alt_claude_slave_acceptance__}"
TIMEOUT_SECONDS="${SLAVE_ACCEPTANCE_TIMEOUT:-2400}"
POLL_SECONDS="${SLAVE_ACCEPTANCE_POLL:-5}"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT_DIR="${1:-$ROOT/diagnostics/reports/$STAMP-worker}"
mkdir -p "$REPORT_DIR"

say(){ printf '[worker-check] %s\n' "$*"; }

[[ -x "$BRIDGE" ]] || { echo "bridge não executável: $BRIDGE" >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 ausente" >&2; exit 2; }
command -v ssh >/dev/null || { echo "ssh ausente" >&2; exit 2; }
command -v timeout >/dev/null || { echo "timeout ausente" >&2; exit 2; }

mcp_call() {
  local tool="$1" args_json="$2" outfile="$3"
  local init call
  init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"alt-claude-worker-check","version":"1"}}}'
  call="{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$tool"),\"arguments\":$args_json}}"
  { printf '%s\n' "$init"; printf '%s\n' "$call"; } | timeout 30 "$BRIDGE" >"$outfile" 2>&1
}

extract_structured() {
  python3 - "$1" <<'PY'
import json,sys
for line in open(sys.argv[1], encoding='utf-8', errors='replace'):
    line=line.strip()
    if not line.startswith('{'): continue
    try: obj=json.loads(line)
    except Exception: continue
    if obj.get('id')==2:
        result=obj.get('result',{})
        print(json.dumps(result.get('structuredContent',{}), ensure_ascii=False))
        raise SystemExit(0)
raise SystemExit(1)
PY
}

say "relatório: $REPORT_DIR"
say "modelo: $MODEL"

say "1/6 validando chamadas MCP"
mcp_call system_status '{}' "$REPORT_DIR/01-system-status.txt"
mcp_call models_list '{}' "$REPORT_DIR/02-models-list.txt"
mcp_call repositories_list '{}' "$REPORT_DIR/03-repositories-list-before.txt"
extract_structured "$REPORT_DIR/01-system-status.txt" >"$REPORT_DIR/01-system-status.json"
extract_structured "$REPORT_DIR/02-models-list.txt" >"$REPORT_DIR/02-models-list.json"

python3 - "$REPORT_DIR/01-system-status.json" "$MODEL" <<'PY'
import json,sys
s=json.load(open(sys.argv[1]))
print('llama_available=', s.get('llama_available'))
print('models=', s.get('models'))
if not s.get('llama_available'):
    raise SystemExit('llama-cli não disponível no executor')
PY

python3 - "$REPORT_DIR/02-models-list.json" "$MODEL" <<'PY'
import json,sys
obj=json.load(open(sys.argv[1])); wanted=sys.argv[2]
models=obj.get('models',[])
if not any(m.get('id')==wanted for m in models):
    raise SystemExit(f'modelo não cadastrado: {wanted}')
print('modelo cadastrado:', wanted)
PY

say "2/6 criando repositório descartável no container"
ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$DOM1_SSH_TARGET" \
  "sudo -n incus exec '$CONTAINER_NAME' -- bash -lc 'rm -rf /srv/alt-claude/repos/$TEST_REPO /srv/alt-claude/state/worktrees/*; install -d -o slave -g slave /srv/alt-claude/repos/$TEST_REPO; runuser -u slave -- bash -lc \"cd /srv/alt-claude/repos/$TEST_REPO && git init -b main && git config user.email slave@example.invalid && git config user.name slave-test && printf \\\"hello before slave\\\\n\\\" > hello.txt && git add hello.txt && git commit -m init\"'" \
  >"$REPORT_DIR/04-test-repo-create.txt" 2>&1

mcp_call repositories_list '{}' "$REPORT_DIR/05-repositories-list-after.txt"

say "3/6 submetendo tarefa real"
ARGS=$(python3 - "$TEST_REPO" "$MODEL" <<'PY'
import json,sys
print(json.dumps({
 'repository':sys.argv[1],
 'objective':'Altere hello.txt para conter exatamente uma linha: hello from alt-claude-slave',
 'allowed_files':['hello.txt'],
 'test_commands':["test \"$(cat hello.txt)\" = \"hello from alt-claude-slave\""],
 'model':sys.argv[2],
 'base_branch':'main'
}, ensure_ascii=False))
PY
)
mcp_call task_submit "$ARGS" "$REPORT_DIR/06-task-submit.txt"
TASK_ID=$(extract_structured "$REPORT_DIR/06-task-submit.txt" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("task_id",""))')
[[ -n "$TASK_ID" ]] || { echo "task_submit não devolveu task_id" >&2; exit 3; }
printf '%s\n' "$TASK_ID" >"$REPORT_DIR/task-id.txt"
say "task_id=$TASK_ID"

say "4/6 aguardando worker"
start=$(date +%s)
while :; do
  args=$(python3 -c 'import json,sys; print(json.dumps({"task_id":sys.argv[1]}))' "$TASK_ID")
  mcp_call task_status "$args" "$REPORT_DIR/07-task-status-latest.txt" || true
  status=$(extract_structured "$REPORT_DIR/07-task-status-latest.txt" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status","unknown"))' 2>/dev/null || echo unknown)
  say "status=$status"
  case "$status" in succeeded|failed|canceled) break;; esac
  now=$(date +%s); (( now-start < TIMEOUT_SECONDS )) || { echo "timeout aguardando tarefa" >&2; break; }
  sleep "$POLL_SECONDS"
done

say "5/6 coletando logs e diff"
args=$(python3 -c 'import json,sys; print(json.dumps({"task_id":sys.argv[1],"max_chars":30000}))' "$TASK_ID")
mcp_call task_logs "$args" "$REPORT_DIR/08-task-logs.txt" || true
args=$(python3 -c 'import json,sys; print(json.dumps({"task_id":sys.argv[1],"max_chars":60000}))' "$TASK_ID")
mcp_call task_diff "$args" "$REPORT_DIR/09-task-diff.txt" || true

say "6/6 validando resultado"
FINAL=$(extract_structured "$REPORT_DIR/07-task-status-latest.txt" 2>/dev/null || echo '{}')
printf '%s\n' "$FINAL" >"$REPORT_DIR/07-task-status-final.json"
final_status=$(printf '%s' "$FINAL" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status","unknown"))')
if [[ "$final_status" == succeeded ]]; then
  echo "PASS: tarefa real concluída" | tee "$REPORT_DIR/RESULT.txt"
  rc=0
else
  echo "FAIL: tarefa terminou com status=$final_status" | tee "$REPORT_DIR/RESULT.txt"
  rc=4
fi

ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$DOM1_SSH_TARGET" \
  "sudo -n incus exec '$CONTAINER_NAME' -- bash -lc 'rm -rf /srv/alt-claude/repos/$TEST_REPO'" \
  >>"$REPORT_DIR/10-cleanup.txt" 2>&1 || true

say "concluído: $REPORT_DIR"
exit "$rc"
