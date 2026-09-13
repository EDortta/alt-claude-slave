# alt-claude-slave

Executor local de tarefas de programacao planejadas por Codex ou Copilot.

O alvo inicial e o Dell PowerEdge T610 (2 x Xeon E5620, 8 nucleos fisicos,
16 threads, 64 GB de RAM, sem GPU de inferencia). O projeto nao tenta substituir
o planejador: recebe uma tarefa pequena, implementa, testa e devolve um diff para
revisao.

## Estrategia

1. Codex ou Copilot envia um contrato pelo MCP.
2. O T610 cria branch e worktree isolados para a tarefa.
3. O modelo local produz somente um unified diff.
4. O worker valida caminhos, aplica o patch e executa os testes declarados.
5. Codex ou Copilot le o diff e decide se ele pode ser integrado.

O modelo local nao deve decidir arquitetura nem trabalhar sem limites de arquivos.

## Modelos iniciais

| Ordem | Perfil | Papel |
|---|---|---|
| 1 | `qwen-coder-3b` | candidato principal: melhor equilibrio esperado |
| 2 | `qwen-coder-7b` | candidato de qualidade, provavelmente mais lento |
| 3 | `qwen-coder-1.5b` | baseline de velocidade e tarefas mecanicas |
| 4 | `deepseek-coder-lite` | experimento-limite; MoE maior, pode ser lento demais |

Todos usam GGUF `Q4_K_M`. Nao incluimos modelos densos de 14B ou maiores na
primeira rodada: caber na RAM nao basta; neste hardware, latencia e custo de
contexto sao os gargalos.

## Inicio rapido no T610

```bash
git clone git@github.com:EDortta/alt-claude-slave.git
cd alt-claude-slave
./scripts/bootstrap-llama.sh
./slave models
./slave smoke qwen-coder-3b
./slave serve qwen-coder-3b
```

O servidor escuta apenas em `127.0.0.1:8080` por padrao e oferece API compativel
com OpenAI. Para expor na rede local conscientemente:

```bash
SLAVE_HOST=0.0.0.0 ./slave serve qwen-coder-3b
```

## Benchmark

```bash
./slave benchmark qwen-coder-3b
./slave benchmark qwen-coder-7b
```

Os logs ficam em `results/` e nao entram no Git. Decisao inicial:

- `>= 4 tokens/s`: operacional para tarefas pequenas;
- `2 a 4 tokens/s`: util em lote, sem interacao frequente;
- `< 2 tokens/s`: retirar do caminho normal;
- qualidade insuficiente nos testes: retirar, independentemente da velocidade.

Comece com contexto de 8K. Contexto maior consome memoria e processamento; o
planejador deve entregar apenas os arquivos e criterios necessarios.

## Contrato de tarefa

Use `tasks/TEMPLATE.md`. Cada tarefa precisa declarar objetivo, arquivos
permitidos, restricoes, comandos de teste e criterio de aceite. O executor deve
parar se precisar sair desse contrato.

## Servidor MCP

`slave-mcp` e um servidor MCP por `stdio`, escrito em Python sem dependencias
externas. Ele nao abre porta TCP. No desenho padrao, o Codex no `devel3` inicia
o processo dentro do container por SSH e `incus exec`.

Ferramentas expostas:

- `system_status`: diagnostico do executor;
- `models_list`: catalogo local;
- `repositories_list`: repositorios previamente autorizados;
- `task_submit`: cria tarefa assincrona;
- `task_status`: acompanha o estado;
- `task_logs`: le o final do log;
- `task_diff`: devolve o patch para revisao;
- `task_cancel`: encerra uma tarefa preservando evidencias.

Uma tarefa executa por vez. As demais permanecem na fila, evitando que dois
modelos disputem CPU e memoria no T610. O worker nunca cria commit, faz push ou
merge. O resultado permanece no worktree e no arquivo de diff.

### Atualizar o container no Dom1

```bash
sudo incus exec alt-claude-slave -- su - slave -c \
  'cd /srv/alt-claude/repos/alt-claude-slave && git pull'
```

### Conectar o Codex no devel3

```bash
./scripts/setup-codex-client.sh
codex mcp list
```

O caminho utilizado e:

```text
Codex -> SSH esteban@dom1 -> sudo incus exec -> slave-mcp
```

O script nao usa Cloudflare e nao exige SSH direto no container.

### Testes

```bash
./tests/run.sh
```

O teste de integracao inicia o MCP, cria um repositorio temporario, executa um
modelo falso, aplica o patch em worktree, roda a validacao e consulta o diff
pelo protocolo.

## Integracao com alt-claude

O MCP e o caminho para delegacao planejador-executor. Um perfil `local-coder`
no `alt-claude` pode continuar sendo usado para conversar diretamente com o
`llama-server`, mas nao substitui o contrato, o worktree e os controles do MCP.
