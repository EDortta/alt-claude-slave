#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOM1_SSH_TARGET="${DOM1_SSH_TARGET:-esteban@dom1.inovacaosistemas.com.br}"
CONTAINER_NAME="${CONTAINER_NAME:-alt-claude-slave}"
MODELS_FILE="${SLAVE_MODELS_FILE:-/srv/alt-claude/repos/alt-claude-slave/config/models.tsv}"
LLAMA_BIN="${LLAMA_BIN:-/home/slave/.local/opt/llama.cpp/bin}"
MODELS_CSV="${SLAVE_LOWLEVEL_MODELS:-qwen-coder-1.5b,qwen-coder-3b}"
TIMEOUT_SECONDS="${SLAVE_LOWLEVEL_TIMEOUT:-90}"
CTX="${SLAVE_LOWLEVEL_CONTEXT:-512}"
THREADS="${SLAVE_LOWLEVEL_THREADS:-12}"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT_DIR="${1:-$ROOT/diagnostics/reports/$STAMP-lowlevel}"
mkdir -p "$REPORT_DIR"
SUMMARY="$REPORT_DIR/summary.tsv"
printf 'model\tcontext\tmax_tokens\ttimeout_s\telapsed_s\trc\tresult\n' >"$SUMMARY"

say(){ printf '[lowlevel] %s\n' "$*"; }

IFS=',' read -r -a MODELS <<< "$MODELS_CSV"
for model in "${MODELS[@]}"; do
  model="${model//[[:space:]]/}"
  [[ -n "$model" ]] || continue
  safe_model="${model//[^A-Za-z0-9._-]/-}"

  for tokens in 1 8 32; do
    dir="$REPORT_DIR/${safe_model}-n${tokens}"
    mkdir -p "$dir"
    say "$model: contexto=$CTX tokens=$tokens timeout=${TIMEOUT_SECONDS}s"

    start=$(date +%s)
    set +e
    ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$DOM1_SSH_TARGET" \
      "sudo -n incus exec '$CONTAINER_NAME' -- runuser -u slave -- bash -lc '
        set -o pipefail
        MODEL_LINE=\$(grep -F \"$model|\" \"$MODELS_FILE\" | head -n1)
        if [[ -z \"\$MODEL_LINE\" ]]; then echo MODEL_NOT_FOUND >&2; exit 44; fi
        IFS=\"|\" read -r MID REPO QUANT MCTX MTHREADS STATUS PURPOSE <<< \"\$MODEL_LINE\"
        OUT=/srv/alt-claude/state/lowlevel-${safe_model}-n${tokens}.out
        ERR=/srv/alt-claude/state/lowlevel-${safe_model}-n${tokens}.err
        : > \"\$OUT\"; : > \"\$ERR\"
        /usr/bin/time -f \"WALL=%e\\nUSER=%U\\nSYS=%S\\nMAXRSS_KB=%M\" -o \"\$ERR.time\" \
          timeout --signal=TERM --kill-after=5 ${TIMEOUT_SECONDS}s \
          \"$LLAMA_BIN/llama-completion\" \
          -hf \"\$REPO:\$QUANT\" \
          -c $CTX -t $THREADS -n $tokens --temp 0 -no-cnv \
          -p \"Return exactly the word OK\" \
          >\"\$OUT\" 2>\"\$ERR\"
        RC=\$?
        echo \"RC=\$RC\" >> \"\$ERR.time\"
        exit \$RC
      '" >"$dir/ssh.txt" 2>&1
    rc=$?
    set -e
    elapsed=$(( $(date +%s) - start ))

    ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$DOM1_SSH_TARGET" \
      "sudo -n incus exec '$CONTAINER_NAME' -- runuser -u slave -- bash -lc 'cat /srv/alt-claude/state/lowlevel-${safe_model}-n${tokens}.out 2>/dev/null || true'" \
      >"$dir/stdout.txt" 2>&1 || true
    ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$DOM1_SSH_TARGET" \
      "sudo -n incus exec '$CONTAINER_NAME' -- runuser -u slave -- bash -lc 'cat /srv/alt-claude/state/lowlevel-${safe_model}-n${tokens}.err 2>/dev/null || true'" \
      >"$dir/stderr.txt" 2>&1 || true
    ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$DOM1_SSH_TARGET" \
      "sudo -n incus exec '$CONTAINER_NAME' -- runuser -u slave -- bash -lc 'cat /srv/alt-claude/state/lowlevel-${safe_model}-n${tokens}.err.time 2>/dev/null || true'" \
      >"$dir/time.txt" 2>&1 || true

    result=FAIL
    if [[ $rc -eq 0 ]]; then result=PASS; fi
    if [[ $rc -eq 124 || $rc -eq 137 || $rc -eq 143 ]]; then result=TIMEOUT; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$model" "$CTX" "$tokens" "$TIMEOUT_SECONDS" "$elapsed" "$rc" "$result" >>"$SUMMARY"

    if [[ "$result" == TIMEOUT && "$tokens" == 1 ]]; then
      say "$model: timeout até para 1 token; pulando 8 e 32"
      printf '%s\t%s\t8\t%s\t0\t-\tSKIP\n' "$model" "$CTX" "$TIMEOUT_SECONDS" >>"$SUMMARY"
      printf '%s\t%s\t32\t%s\t0\t-\tSKIP\n' "$model" "$CTX" "$TIMEOUT_SECONDS" >>"$SUMMARY"
      break
    fi
  done
done

say "concluído: $REPORT_DIR"
cat "$SUMMARY"
printf '\n[lowlevel] publique com:\n  bash diagnostics/publish-report.sh %q\n' "$REPORT_DIR"
