#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "Uso interno: benchmark.sh <id> <repo> <quant> <threads>" >&2
  exit 2
fi

MODEL_ID="$1"
MODEL_REPO="$2"
MODEL_QUANT="$3"
MODEL_THREADS="$4"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LLAMA_BIN="${LLAMA_BIN:-$HOME/.local/opt/llama.cpp/bin}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT="$ROOT_DIR/results/${STAMP}-${MODEL_ID}.log"

mkdir -p "$ROOT_DIR/results"

if [[ ! -x /usr/bin/time ]]; then
  echo "Erro: /usr/bin/time nao encontrado. Instale o pacote 'time'." >&2
  exit 1
fi

PROMPT='Voce e um implementador. Escreva somente codigo Python. Implemente uma funcao LRUCache com get e put, capacidade configuravel, O(1), type hints e sem dependencias externas. Inclua cinco testes usando unittest, cobrindo atualizacao, despejo e capacidade um.'

{
  echo "model=$MODEL_ID"
  echo "repo=$MODEL_REPO"
  echo "quant=$MODEL_QUANT"
  echo "threads=$MODEL_THREADS"
  echo "date=$STAMP"
  uname -a
  lscpu
  echo
  /usr/bin/time -v "$LLAMA_BIN/llama-cli" \
    -hf "$MODEL_REPO:$MODEL_QUANT" \
    -c 4096 \
    -t "$MODEL_THREADS" \
    -n 768 \
    --temp 0 \
    -p "$PROMPT"
} 2>&1 | tee "$RESULT"

echo "Resultado: $RESULT"
