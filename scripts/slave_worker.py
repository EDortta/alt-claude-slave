#!/usr/bin/env python3
"""One-task worker: ask the local model for a constrained patch, apply, and test."""

from __future__ import annotations

import fcntl
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from slave_common import (
    LLAMA_BIN,
    STATE_DIR,
    get_model,
    read_json,
    task_file,
    validate_repository,
    write_json_atomic,
)


MAX_SOURCE_CHARS = 12000
MODEL_TIMEOUT_SECONDS = 3600
TEST_TIMEOUT_SECONDS = 900


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


def log(message: str) -> None:
    print(f"[{now()}] {message}", flush=True)


def run(command: list[str], *, cwd: Path | None = None, timeout: int = 300, capture: bool = True) -> subprocess.CompletedProcess[str]:
    log("$ " + " ".join(command))
    return subprocess.run(command, cwd=cwd, text=True, capture_output=capture, timeout=timeout, check=True)


def update(path: Path, task: dict[str, Any], status: str, **values: Any) -> None:
    task.update(values)
    task["status"] = status
    task["updated_at"] = now()
    write_json_atomic(path, task)


def resolve_base(repository: Path, branch: str) -> str:
    for reference in (branch, f"origin/{branch}"):
        result = subprocess.run(
            ["git", "-C", str(repository), "rev-parse", "--verify", f"{reference}^{{commit}}"],
            text=True,
            capture_output=True,
        )
        if result.returncode == 0:
            return reference
    raise RuntimeError(f"branch base nao encontrada: {branch}")


def collect_sources(worktree: Path, allowed_files: list[str]) -> str:
    parts: list[str] = []
    used = 0
    for relative in allowed_files:
        path = worktree / relative
        if not path.exists():
            content = "<ARQUIVO INEXISTENTE; pode ser criado>"
        elif not path.is_file():
            raise RuntimeError(f"allowed_files contem algo que nao e arquivo: {relative}")
        else:
            content = path.read_text(encoding="utf-8", errors="replace")
        block = f"\n===== {relative} =====\n{content}\n"
        if used + len(block) > MAX_SOURCE_CHARS:
            remaining = MAX_SOURCE_CHARS - used
            if remaining > 200:
                parts.append(block[:remaining] + "\n<CONTEUDO TRUNCADO>\n")
            break
        parts.append(block)
        used += len(block)
    return "".join(parts)


def build_prompt(task: dict[str, Any], sources: str) -> str:
    allowed = "\n".join(f"- {item}" for item in task["allowed_files"])
    tests = "\n".join(f"- {item}" for item in task["test_commands"]) or "- nenhum comando informado"
    user_prompt = f"""OBJETIVO
{task['objective']}

ARQUIVOS QUE PODEM SER ALTERADOS
{allowed}

TESTES QUE SERAO EXECUTADOS
{tests}

REGRAS OBRIGATORIAS
1. Nao altere arquitetura nem arquivos fora da lista.
2. Responda somente com um unified diff valido para git apply.
3. O diff deve usar caminhos a/arquivo e b/arquivo e comecar com diff --git.
4. Nao use cercas Markdown, explicacoes ou comandos de shell.
5. Se nao for possivel cumprir, responda exatamente IMPOSSIVEL seguido de uma frase curta.

CONTEUDO ATUAL
{sources}"""
    system_prompt = "Voce e um implementador de software trabalhando sob contrato estrito. Obedeca literalmente ao formato de saida solicitado."
    return (
        "<|im_start|>system\n"
        + system_prompt
        + "<|im_end|>\n"
        + "<|im_start|>user\n"
        + user_prompt
        + "<|im_end|>\n"
        + "<|im_start|>assistant\n"
    )


def extract_patch(output: str) -> str:
    match = re.search(r"(?m)^diff --git ", output)
    if not match:
        raise RuntimeError("o modelo nao produziu um unified diff")
    patch = output[match.start():]
    fence = re.search(r"(?m)^```\s*$", patch)
    if fence:
        patch = patch[:fence.start()]
    end_token = patch.find("<|im_end|>")
    if end_token >= 0:
        patch = patch[:end_token]
    return patch.rstrip() + "\n"


def staged_files(worktree: Path) -> set[str]:
    result = run(["git", "diff", "--cached", "--name-only", "--"], cwd=worktree)
    return {line for line in result.stdout.splitlines() if line}


def reject_symlinks(worktree: Path, changed: set[str]) -> None:
    links = [relative for relative in changed if (worktree / relative).is_symlink()]
    if links:
        raise RuntimeError("patch criou ou alterou links simbolicos: " + ", ".join(sorted(links)))


def main(task_id: str) -> int:
    path = task_file(task_id)
    task: dict[str, Any] | None = None
    for _ in range(500):
        candidate_task = read_json(path)
        if candidate_task.get("pid") == os.getpid():
            task = candidate_task
            break
        time.sleep(0.01)
    if task is None:
        raise RuntimeError("o processo nao foi confirmado no registro da tarefa")
    lock_path = STATE_DIR / "worker.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)

    with lock_path.open("w", encoding="utf-8") as lock:
        log("Aguardando slot exclusivo de inferencia")
        fcntl.flock(lock, fcntl.LOCK_EX)
        latest = read_json(path)
        if latest.get("status") == "canceled":
            log("Tarefa cancelada antes da execucao")
            return 0
        task = latest
        update(path, task, "running", started_at=now())

        repository = validate_repository(task["repository"])
        worktree = Path(task["worktree"])
        model = get_model(task["model"])
        llama_cli = LLAMA_BIN / "llama-completion"
        if not llama_cli.is_file():
            raise RuntimeError(f"llama-completion nao encontrado: {llama_cli}")
        if worktree.exists():
            raise RuntimeError(f"worktree ja existe: {worktree}")

        base = resolve_base(repository, task["base_branch"])
        run(["git", "-C", str(repository), "worktree", "add", "-b", task["branch"], str(worktree), base], timeout=300)
        sources = collect_sources(worktree, task["allowed_files"])
        prompt = build_prompt(task, sources)
        prompt_file = STATE_DIR / "tasks" / f"{task_id}.prompt"
        prompt_file.write_text(prompt, encoding="utf-8")

        log(f"Executando modelo {model['id']} em batch ChatML")
        model_result = subprocess.run(
            [
                str(llama_cli),
                "-hf", f"{model['repository']}:{model['quant']}",
                "-c", str(model["context"]),
                "-t", str(min(model["threads"], os.cpu_count() or model["threads"])),
                "-n", "512",
                "--temp", "0",
                "-no-cnv",
                "-f", str(prompt_file),
            ],
            cwd=worktree,
            text=True,
            capture_output=True,
            timeout=MODEL_TIMEOUT_SECONDS,
        )
        raw_file = STATE_DIR / "tasks" / f"{task_id}.model-output.txt"
        raw_file.write_text(model_result.stdout + "\n--- STDERR ---\n" + model_result.stderr, encoding="utf-8")
        if model_result.returncode != 0:
            raise RuntimeError(f"llama-completion terminou com codigo {model_result.returncode}")

        patch = extract_patch(model_result.stdout)
        candidate = STATE_DIR / "tasks" / f"{task_id}.candidate.diff"
        candidate.write_text(patch, encoding="utf-8")
        run(["git", "apply", "--check", str(candidate)], cwd=worktree)
        run(["git", "apply", str(candidate)], cwd=worktree)
        run(["git", "add", "--all"], cwd=worktree)

        changed = staged_files(worktree)
        forbidden = changed - set(task["allowed_files"])
        if forbidden:
            raise RuntimeError("modelo tentou alterar arquivos proibidos: " + ", ".join(sorted(forbidden)))
        reject_symlinks(worktree, changed)
        if not changed:
            raise RuntimeError("o patch nao produziu alteracoes")

        for command in task["test_commands"]:
            log(f"Teste: {command}")
            result = subprocess.run(
                ["/bin/bash", "-lc", command],
                cwd=worktree,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=TEST_TIMEOUT_SECONDS,
            )
            print(result.stdout, end="", flush=True)
            if result.returncode != 0:
                raise RuntimeError(f"teste falhou com codigo {result.returncode}: {command}")

        post_test_changes = run(["git", "diff", "--name-only", "--"], cwd=worktree)
        if post_test_changes.stdout.strip():
            raise RuntimeError("testes alteraram arquivos rastreados: " + ", ".join(post_test_changes.stdout.splitlines()))
        diff_result = run(["git", "diff", "--cached", "--binary", "--"], cwd=worktree)
        Path(task["diff_file"]).write_text(diff_result.stdout, encoding="utf-8")
        update(path, task, "succeeded", finished_at=now(), changed_files=sorted(changed))
        log("Tarefa concluida; diff pronto para revisao")
        return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Uso: slave_worker.py TASK_ID", file=sys.stderr)
        raise SystemExit(2)
    task_path = task_file(sys.argv[1])
    try:
        raise SystemExit(main(sys.argv[1]))
    except Exception as exc:
        try:
            failed = read_json(task_path)
            update(task_path, failed, "failed", finished_at=now(), error=str(exc))
        except Exception as state_exc:
            log(f"Falha ao registrar erro: {state_exc}")
        log(f"ERRO: {type(exc).__name__}: {exc}")
        raise SystemExit(1)
