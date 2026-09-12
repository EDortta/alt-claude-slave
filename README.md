# alt-claude-slave

Executor local de tarefas de programacao planejadas por Codex ou Copilot.

O alvo inicial e o Dell PowerEdge T610 (2 x Xeon E5620, 8 nucleos fisicos,
16 threads, 64 GB de RAM, sem GPU de inferencia). O projeto nao tenta substituir
o planejador: recebe uma tarefa pequena, implementa, testa e devolve um diff para
revisao.

## Estrategia

1. Codex ou Copilot escreve um contrato em `tasks/`.
2. O T610 executa a tarefa com um modelo local servido por `llama.cpp`.
3. Testes deterministas validam o resultado.
4. Codex ou Copilot revisa o diff e decide se ele pode ser integrado.

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

## Integracao futura com alt-claude

O ponto de integracao sera um perfil `local-coder` no projeto `alt-claude`,
apontando para `http://dom1:8080/v1`. Esta primeira etapa mede capacidade real
antes de automatizar delegacao, commits ou fallback.

