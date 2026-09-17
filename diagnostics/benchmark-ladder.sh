#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOM1_SSH_TARGET="${DOM1_SSH_TARGET:-esteban@dom1.inovacaosistemas.com.br}"
CONTAINER_NAME="${CONTAINER_NAME:-alt-claude-slave}"
REMOTE_REPO="${REMOTE_REPO:-/srv/alt-claude/repos/alt-claude-slave}"
BRIDGE="${ALT_CLAUDE_SLAVE_MCP:-$HOME/.local/bin/alt-claude-slave-mcp}"
MODELS_CSV="${SLAVE_BENCH_MODELS:-qwen-coder-1.5b}"
LEVELS_CSV="${SLAVE_BENCH_LEVELS:-medium}"
POLL_SECONDS="${SLAVE_BENCH_POLL:-5}"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT_DIR="${1:-$ROOT/diagnostics/reports/$STAMP-benchmark}"
mkdir -p "$REPORT_DIR"
SUMMARY="$REPORT_DIR/summary.tsv"
printf 'model\tlevel\tmax_tokens\ttimeout_s\telapsed_s\tstatus\tresult\ttask_id\n' >"$SUMMARY"

say(){ printf '[benchmark] %s\n' "$*"; }
[[ -x "$BRIDGE" ]] || { echo "bridge não executável: $BRIDGE" >&2; exit 2; }

is_infra_error_file() {
  local file="$1"
  grep -Eqi 'Could not resolve hostname|Name or service not known|Connection timed out|No route to host|Connection refused|Connection reset|ssh:|incus.*(error|failed)' "$file" 2>/dev/null
}

mcp_call() {
  local tool="$1" args_json="$2" outfile="$3"
  local init call
  init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"alt-claude-benchmark","version":"3"}}}'
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
    if obj.get('id') == 2:
        print(json.dumps(obj.get('result',{}).get('structuredContent',{}), ensure_ascii=False))
        raise SystemExit(0)
raise SystemExit(1)
PY
}

case_timeout() {
  case "$1" in
    easy) printf '%s' "${SLAVE_BENCH_EASY_TIMEOUT:-300}" ;;
    medium) printf '%s' "${SLAVE_BENCH_MEDIUM_TIMEOUT:-600}" ;;
    deep) printf '%s' "${SLAVE_BENCH_DEEP_TIMEOUT:-1200}" ;;
    *) echo "nível inválido: $1" >&2; return 2 ;;
  esac
}

case_tokens() {
  case "$1" in
    easy) printf '%s' "${SLAVE_BENCH_EASY_TOKENS:-96}" ;;
    medium) printf '%s' "${SLAVE_BENCH_MEDIUM_TOKENS:-192}" ;;
    deep) printf '%s' "${SLAVE_BENCH_DEEP_TOKENS:-384}" ;;
    *) echo "nível inválido: $1" >&2; return 2 ;;
  esac
}

set_worker_tokens() {
  local tokens="$1"
  ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$DOM1_SSH_TARGET" \
    "sudo -n incus exec '$CONTAINER_NAME' -- runuser -u slave -- python3 - '$REMOTE_REPO/scripts/slave_worker.py' '$tokens'" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); n=sys.argv[2]
s=p.read_text(encoding='utf-8')
s,new_count=re.subn(r'(\"-n\",\s*\")\d+(\")', rf'\g<1>{n}\g<2>', s, count=1)
if new_count != 1:
    raise SystemExit('não encontrei limite -n no worker')
p.write_text(s, encoding='utf-8')
PY
}

prepare_repo() {
  local repo="$1" level="$2"
  ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$DOM1_SSH_TARGET" \
    "sudo -n incus exec '$CONTAINER_NAME' -- runuser -u slave -- python3 - '$repo' '$level'" <<'PY'
import shutil, subprocess, sys
from pathlib import Path
repo, level = sys.argv[1], sys.argv[2]
root = Path('/srv/alt-claude/repos') / repo
shutil.rmtree(root, ignore_errors=True)
root.mkdir(parents=True)
subprocess.run(['git','init','-b','main'], cwd=root, check=True, stdout=subprocess.DEVNULL)
subprocess.run(['git','config','user.email','slave@example.invalid'], cwd=root, check=True)
subprocess.run(['git','config','user.name','slave-benchmark'], cwd=root, check=True)
if level == 'easy':
    (root/'hello.txt').write_text('hello before slave\n')
elif level == 'medium':
    (root/'clamp_utils.py').write_text('def clamp(value, minimum, maximum):\n    return value\n')
    (root/'test_clamp_utils.py').write_text('''import unittest\nfrom clamp_utils import clamp\n\nclass TestClamp(unittest.TestCase):\n    def test_inside(self): self.assertEqual(clamp(5, 1, 10), 5)\n    def test_low(self): self.assertEqual(clamp(-2, 1, 10), 1)\n    def test_high(self): self.assertEqual(clamp(20, 1, 10), 10)\n    def test_invalid(self):\n        with self.assertRaises(ValueError): clamp(1, 5, 2)\n\nif __name__ == "__main__": unittest.main()\n''')
elif level == 'deep':
    (root/'events.py').write_text('def summarize_events(events):\n    return {}\n')
    (root/'test_events.py').write_text('''import copy, unittest\nfrom events import summarize_events\n\nclass TestEvents(unittest.TestCase):\n    def test_groups(self):\n        data=[{"user":"ana","action":"buy","value":10},{"user":"ana","action":"view","value":2},{"user":"bob","action":"buy","value":7},{"user":"ana","action":"buy","value":3}]\n        original=copy.deepcopy(data)\n        self.assertEqual(summarize_events(data), {"ana":{"count":3,"total":15,"actions":["buy","view"]},"bob":{"count":1,"total":7,"actions":["buy"]}})\n        self.assertEqual(data, original)\n    def test_empty(self): self.assertEqual(summarize_events([]), {})\n    def test_missing_key(self):\n        with self.assertRaises(ValueError): summarize_events([{"user":"ana","action":"buy"}])\n\nif __name__ == "__main__": unittest.main()\n''')
else:
    raise SystemExit('unknown level')
subprocess.run(['git','add','.'], cwd=root, check=True)
subprocess.run(['git','commit','-m','benchmark fixture'], cwd=root, check=True, stdout=subprocess.DEVNULL)
PY
}

case_args() {
  local repo="$1" model="$2" level="$3"
  python3 - "$repo" "$model" "$level" <<'PY'
import json,sys
repo,model,level=sys.argv[1:]
if level == 'easy':
    objective='Altere hello.txt para conter exatamente uma linha: hello from alt-claude-slave'
    allowed=['hello.txt']; tests=['test "$(cat hello.txt)" = "hello from alt-claude-slave"']
elif level == 'medium':
    objective='Implemente clamp(value, minimum, maximum). Se minimum > maximum, levante ValueError. Valores abaixo do minimo retornam minimum, acima do maximo retornam maximum, e valores dentro do intervalo permanecem iguais.'
    allowed=['clamp_utils.py']; tests=['python3 -m unittest -q test_clamp_utils.py']
else:
    objective='Implemente summarize_events(events). Cada evento e um dict com user, action e value. Retorne um dict por usuario com count, total (soma de value) e actions (lista unica em ordem alfabetica). Lista vazia retorna dict vazio. Se qualquer evento nao tiver user, action ou value, levante ValueError. Nao modifique a entrada.'
    allowed=['events.py']; tests=['python3 -m unittest -q test_events.py']
print(json.dumps({'repository':repo,'objective':objective,'allowed_files':allowed,'test_commands':tests,'model':model,'base_branch':'main'}, ensure_ascii=False))
PY
}

collect_remote_artifacts() {
  local task_id="$1" dir="$2"
  ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$DOM1_SSH_TARGET" \
    "sudo -n incus exec '$CONTAINER_NAME' -- runuser -u slave -- bash -lc 'cat /srv/alt-claude/state/tasks/$task_id.model-output.txt 2>/dev/null || true'" >"$dir/model-output.txt" 2>&1 || true
  ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$DOM1_SSH_TARGET" \
    "sudo -n incus exec '$CONTAINER_NAME' -- runuser -u slave -- bash -lc 'cat /srv/alt-claude/state/tasks/$task_id.prompt 2>/dev/null || true'" >"$dir/prompt.txt" 2>&1 || true
}

IFS=',' read -r -a MODELS <<< "$MODELS_CSV"
IFS=',' read -r -a LEVELS <<< "$LEVELS_CSV"
say "relatório: $REPORT_DIR"
say "modelos: ${MODELS[*]}"
say "níveis: ${LEVELS[*]}"

abort_all=0
for model in "${MODELS[@]}"; do
  model="${model//[[:space:]]/}"
  [[ -n "$model" ]] || continue
  stop_model=0
  for level in "${LEVELS[@]}"; do
    level="${level//[[:space:]]/}"
    [[ -n "$level" ]] || continue
    timeout_s="$(case_timeout "$level")"
    token_budget="$(case_tokens "$level")"
    if (( stop_model )); then
      printf '%s\t%s\t%s\t%s\t0\tskipped\tSKIP\t-\n' "$model" "$level" "$token_budget" "$timeout_s" >>"$SUMMARY"
      say "$model/$level: SKIP"
      continue
    fi

    safe_model="${model//[^A-Za-z0-9._-]/-}"
    repo="alt-claude-bench-${safe_model}-${level}"
    dir="$REPORT_DIR/${safe_model}-${level}"
    mkdir -p "$dir"
    say "$model/$level: orçamento=${token_budget} tokens timeout=${timeout_s}s"

    if ! set_worker_tokens "$token_budget" >"$dir/worker-token-budget.txt" 2>&1; then
      printf '%s\t%s\t%s\t%s\t0\tinfra-error\tINFRA_ERROR\t-\n' "$model" "$level" "$token_budget" "$timeout_s" >>"$SUMMARY"
      say "$model/$level: INFRA_ERROR configurando worker"
      abort_all=1
      break
    fi
    if ! prepare_repo "$repo" "$level" >"$dir/repo-create.txt" 2>&1; then
      printf '%s\t%s\t%s\t%s\t0\tinfra-error\tINFRA_ERROR\t-\n' "$model" "$level" "$token_budget" "$timeout_s" >>"$SUMMARY"
      say "$model/$level: INFRA_ERROR preparando repo"
      abort_all=1
      break
    fi

    args="$(case_args "$repo" "$model" "$level")"
    start_epoch=$(date +%s)
    if ! mcp_call task_submit "$args" "$dir/task-submit.txt"; then
      elapsed=$(( $(date +%s) - start_epoch ))
      status=submit-error; result=FAIL
      if is_infra_error_file "$dir/task-submit.txt"; then status=infra-error; result=INFRA_ERROR; abort_all=1; fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t-\n' "$model" "$level" "$token_budget" "$timeout_s" "$elapsed" "$status" "$result" >>"$SUMMARY"
      say "$model/$level: $result no submit"
      (( abort_all )) && break
      continue
    fi

    task_id=$(extract_structured "$dir/task-submit.txt" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("task_id",""))' 2>/dev/null || true)
    if [[ -z "$task_id" ]]; then
      elapsed=$(( $(date +%s) - start_epoch ))
      printf '%s\t%s\t%s\t%s\t%s\tsubmit-error\tFAIL\t-\n' "$model" "$level" "$token_budget" "$timeout_s" "$elapsed" >>"$SUMMARY"
      continue
    fi
    printf '%s\n' "$task_id" >"$dir/task-id.txt"

    final_status=unknown; result=FAIL
    while :; do
      a=$(python3 -c 'import json,sys; print(json.dumps({"task_id":sys.argv[1]}))' "$task_id")
      if ! mcp_call task_status "$a" "$dir/task-status-latest.txt"; then
        elapsed=$(( $(date +%s) - start_epoch ))
        if is_infra_error_file "$dir/task-status-latest.txt"; then
          final_status=infra-error; result=INFRA_ERROR; abort_all=1
          say "$model/$level: INFRA_ERROR em ${elapsed}s"
          break
        fi
      fi
      final_status=$(extract_structured "$dir/task-status-latest.txt" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status","unknown"))' 2>/dev/null || echo unknown)
      elapsed=$(( $(date +%s) - start_epoch ))
      say "$model/$level: status=$final_status elapsed=${elapsed}s/${timeout_s}s"
      case "$final_status" in
        succeeded) result=PASS; break ;;
        failed|canceled) result=FAIL; break ;;
      esac
      if (( elapsed >= timeout_s )); then
        mcp_call task_cancel "$a" "$dir/task-cancel.txt" || true
        final_status=timeout; result=TIMEOUT; stop_model=1
        break
      fi
      sleep "$POLL_SECONDS"
    done

    elapsed=$(( $(date +%s) - start_epoch ))
    if [[ "$result" != INFRA_ERROR ]]; then
      a=$(python3 -c 'import json,sys; print(json.dumps({"task_id":sys.argv[1],"max_chars":30000}))' "$task_id"); mcp_call task_logs "$a" "$dir/task-logs.txt" || true
      a=$(python3 -c 'import json,sys; print(json.dumps({"task_id":sys.argv[1],"max_chars":60000}))' "$task_id"); mcp_call task_diff "$a" "$dir/task-diff.txt" || true
      collect_remote_artifacts "$task_id" "$dir"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$model" "$level" "$token_budget" "$timeout_s" "$elapsed" "$final_status" "$result" "$task_id" >>"$SUMMARY"
    say "$model/$level: $result em ${elapsed}s"
    (( abort_all )) && break
  done
  (( abort_all )) && break
done

say "concluído"
cat "$SUMMARY"
printf '\n[benchmark] publique este diretório com:\n  bash diagnostics/publish-report.sh %q\n' "$REPORT_DIR"