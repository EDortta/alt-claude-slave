# Diagnóstico do alt-claude-slave MCP

Execute no `devel3`, a partir da raiz deste repositório:

```bash
bash diagnostics/run-all.sh
```

O script não lê nem imprime conteúdo de chaves/tokens. Ele coleta apenas caminhos, versões, status de comandos, configuração pública do MCP, conectividade SSH/Incus e respostas MCP.

Saída:

```text
diagnostics/reports/YYYYMMDD-HHMMSS/
```

Depois de executar, revise rapidamente os arquivos e suba somente esse diretório:

```bash
git add diagnostics/reports/<timestamp>
git commit -m "diag: capture alt-claude-slave MCP failure"
git push
```

Variáveis opcionais:

```bash
DOM1_SSH_TARGET=esteban@dom1.inovacaosistemas.com.br
CONTAINER_NAME=alt-claude-slave
REMOTE_REPO=/srv/alt-claude/repos/alt-claude-slave
MCP_NAME=alt-claude-slave
```
