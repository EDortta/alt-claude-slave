#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT="${1:-}"
[[ -n "$REPORT" ]] || { echo "Uso: diagnostics/publish-report.sh diagnostics/reports/TIMESTAMP" >&2; exit 2; }
case "$REPORT" in
  diagnostics/reports/*) ;;
  "$ROOT"/diagnostics/reports/*) ;;
  *) echo "Recuso publicar caminho fora de diagnostics/reports/: $REPORT" >&2; exit 2 ;;
esac

cd "$ROOT"
[[ -d "$REPORT" ]] || { echo "Relatório não encontrado: $REPORT" >&2; exit 2; }

echo "Arquivos que serão enviados:"
find "$REPORT" -maxdepth 1 -type f -printf '  %p\n' | sort

echo
echo "Faça uma revisão visual. O coletor tenta não incluir segredos, mas o push é definitivo para o histórico Git."
read -r -p "Publicar este relatório no branch atual? [y/N] " answer
[[ "$answer" == "y" || "$answer" == "Y" ]] || { echo "Cancelado."; exit 1; }

git add "$REPORT"
git diff --cached --stat
git commit -m "diag: capture alt-claude-slave MCP failure"
git push -u origin HEAD
