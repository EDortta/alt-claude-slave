#!/usr/bin/env python3
"""Minimal MCP stdio server for the T610 implementation worker."""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from slave_common import (
    LLAMA_BIN,
    PROJECT_ROOT,
    REPOS_DIR,
    STATE_DIR,
    ensure_state_dirs,
    get_model,
    list_repositories,
    load_models,
    read_json,
    task_file,
    validate_allowed_files,
    validate_ref,
    validate_repository,
    validate_test_commands,
    write_json_atomic,
)


SERVER_VERSION = "0.1.0"
DEFAULT_PROTOCOL = "2026-07-28"


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def text_result(value: Any, *, error: bool = False) -> dict[str, Any]:
    text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, indent=2)
    return {
        "content": [{"type": "text", "text": text}],
        "structuredContent": value if isinstance(value, dict) else {"result": value},
        "isError": error,
    }


TOOLS: list[dict[str, Any]] = [
    {
        "name": "system_status",
        "description": "Mostra o estado do executor, caminhos, modelos e quantidade de tarefas.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
        "annotations": {"readOnlyHint": True, "destructiveHint": False},
    },
    {
        "name": "models_list",
        "description": "Lista os perfis locais de modelos disponiveis no T610.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
        "annotations": {"readOnlyHint": True, "destructiveHint": False},
    },
    {
        "name": "repositories_list",
        "description": "Lista somente repositorios Git ja autorizados e presentes no volume do executor.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
        "annotations": {"readOnlyHint": True, "destructiveHint": False},
    },
    {
        "name": "task_submit",
        "description": "Enfileira implementacao local em worktree isolado. O modelo so pode alterar allowed_files.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "repository": {"type": "string", "description": "Nome retornado por repositories_list."},
                "objective": {"type": "string", "minLength": 10, "maxLength": 4000},
                "allowed_files": {"type": "array", "items": {"type": "string"}, "minItems": 1, "maxItems": 40},
                "test_commands": {"type": "array", "items": {"type": "string"}, "maxItems": 8, "default": []},
                "model": {"type": "string", "default": "qwen-coder-3b"},
                "base_branch": {"type": "string", "default": "main"},
            },
            "required": ["repository", "objective", "allowed_files"],
            "additionalProperties": False,
        },
        "annotations": {"readOnlyHint": False, "destructiveHint": False},
    },
    {
        "name": "task_status",
        "description": "Consulta metadados e estado atual de uma tarefa.",
        "inputSchema": {
            "type": "object",
            "properties": {"task_id": {"type": "string"}},
            "required": ["task_id"],
            "additionalProperties": False,
        },
        "annotations": {"readOnlyHint": True, "destructiveHint": False},
    },
    {
        "name": "task_logs",
        "description": "Retorna o final do log de uma tarefa, limitado para proteger o contexto do planejador.",
        "inputSchema": {
            "type": "object",
            "properties": {"task_id": {"type": "string"}, "max_chars": {"type": "integer", "minimum": 1000, "maximum": 30000, "default": 12000}},
            "required": ["task_id"],
            "additionalProperties": False,
        },
        "annotations": {"readOnlyHint": True, "destructiveHint": False},
    },
    {
        "name": "task_diff",
        "description": "Retorna o diff produzido pelo modelo local para revisao do planejador.",
        "inputSchema": {
            "type": "object",
            "properties": {"task_id": {"type": "string"}, "max_chars": {"type": "integer", "minimum": 1000, "maximum": 60000, "default": 30000}},
            "required": ["task_id"],
            "additionalProperties": False,
        },
        "annotations": {"readOnlyHint": True, "destructiveHint": False},
    },
    {
        "name": "task_cancel",
        "description": "Cancela uma tarefa enfileirada ou em execucao sem remover seus logs.",
        "inputSchema": {
            "type": "object",
            "properties": {"task_id": {"type": "string"}},
            "required": ["task_id"],
            "additionalProperties": False,
        },
        "annotations": {"readOnlyHint": False, "destructiveHint": True},
    },
]


def load_task(task_id: str) -> tuple[Path, dict[str, Any]]:
    path = task_file(task_id)
    if not path.exists():
        raise ValueError(f"tarefa nao encontrada: {task_id}")
    return path, read_json(path)


def tool_system_status(_: dict[str, Any]) -> dict[str, Any]:
    ensure_state_dirs()
    statuses: dict[str, int] = {}
    for path in (STATE_DIR / "tasks").glob("*.json"):
        try:
            status = str(read_json(path).get("status", "unknown"))
        except (OSError, ValueError, json.JSONDecodeError):
            status = "invalid"
        statuses[status] = statuses.get(status, 0) + 1
    return {
        "server_version": SERVER_VERSION,
        "project_root": str(PROJECT_ROOT),
        "repos_dir": str(REPOS_DIR),
        "state_dir": str(STATE_DIR),
        "llama_bin": str(LLAMA_BIN),
        "llama_available": (LLAMA_BIN / "llama-cli").is_file(),
        "repositories": len(list_repositories()),
        "models": len(load_models()),
        "tasks": statuses,
    }


def tool_task_submit(arguments: dict[str, Any]) -> dict[str, Any]:
    ensure_state_dirs()
    repository_value = arguments.get("repository", "")
    objective_value = arguments.get("objective", "")
    model_value = arguments.get("model", "qwen-coder-3b")
    branch_value = arguments.get("base_branch", "main")
    if not all(isinstance(value, str) for value in (repository_value, objective_value, model_value, branch_value)):
        raise ValueError("repository, objective, model e base_branch devem ser strings")
    repository = repository_value
    objective = objective_value.strip()
    if len(objective) < 10 or len(objective) > 4000:
        raise ValueError("objective deve ter entre 10 e 4000 caracteres")
    validate_repository(repository)
    allowed_files = validate_allowed_files(arguments.get("allowed_files", []))
    test_commands = validate_test_commands(arguments.get("test_commands", []))
    model_id = model_value
    get_model(model_id)
    base_branch = validate_ref(branch_value)

    task_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:8]
    task = {
        "task_id": task_id,
        "status": "queued",
        "created_at": utc_now(),
        "updated_at": utc_now(),
        "repository": repository,
        "objective": objective,
        "allowed_files": allowed_files,
        "test_commands": test_commands,
        "model": model_id,
        "base_branch": base_branch,
        "branch": f"slave/{task_id}",
        "worktree": str(STATE_DIR / "worktrees" / task_id),
        "log_file": str(STATE_DIR / "tasks" / f"{task_id}.log"),
        "diff_file": str(STATE_DIR / "tasks" / f"{task_id}.diff"),
    }
    path = task_file(task_id)
    write_json_atomic(path, task)

    log_handle = Path(task["log_file"]).open("ab", buffering=0)
    try:
        process = subprocess.Popen(
            [sys.executable, str(PROJECT_ROOT / "scripts/slave_worker.py"), task_id],
            stdin=subprocess.DEVNULL,
            stdout=log_handle,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            close_fds=True,
        )
    finally:
        log_handle.close()
    task["pid"] = process.pid
    write_json_atomic(path, task)
    return {"task_id": task_id, "status": "queued", "message": "Tarefa enfileirada. Consulte task_status e task_logs."}


def tool_task_status(arguments: dict[str, Any]) -> dict[str, Any]:
    _, task = load_task(str(arguments.get("task_id", "")))
    visible = dict(task)
    visible.pop("objective", None)
    return visible


def tail_file(path: Path, max_chars: int) -> str:
    if not path.exists():
        return ""
    with path.open("rb") as handle:
        handle.seek(0, os.SEEK_END)
        size = handle.tell()
        handle.seek(max(0, size - max_chars * 4))
        value = handle.read().decode("utf-8", errors="replace")
    return value[-max_chars:]


def tool_task_logs(arguments: dict[str, Any]) -> dict[str, Any]:
    _, task = load_task(str(arguments.get("task_id", "")))
    limit = int(arguments.get("max_chars", 12000))
    if not 1000 <= limit <= 30000:
        raise ValueError("max_chars fora do intervalo 1000..30000")
    return {"task_id": task["task_id"], "status": task["status"], "log": tail_file(Path(task["log_file"]), limit)}


def tool_task_diff(arguments: dict[str, Any]) -> dict[str, Any]:
    _, task = load_task(str(arguments.get("task_id", "")))
    limit = int(arguments.get("max_chars", 30000))
    if not 1000 <= limit <= 60000:
        raise ValueError("max_chars fora do intervalo 1000..60000")
    diff = tail_file(Path(task["diff_file"]), limit)
    return {"task_id": task["task_id"], "status": task["status"], "truncated": Path(task["diff_file"]).exists() and Path(task["diff_file"]).stat().st_size > len(diff.encode()), "diff": diff}


def tool_task_cancel(arguments: dict[str, Any]) -> dict[str, Any]:
    path, task = load_task(str(arguments.get("task_id", "")))
    if task.get("status") in {"succeeded", "failed", "canceled"}:
        return {"task_id": task["task_id"], "status": task["status"], "message": "Tarefa ja terminou."}
    pid = task.get("pid")
    if isinstance(pid, int) and pid > 1:
        try:
            command_line = Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\x00", b" ").decode(errors="replace")
            if "slave_worker.py" in command_line and task["task_id"] in command_line:
                os.killpg(pid, signal.SIGTERM)
            else:
                raise ValueError("PID da tarefa foi reutilizado; cancelamento recusado")
        except ProcessLookupError:
            pass
        except FileNotFoundError:
            pass
    task["status"] = "canceled"
    task["updated_at"] = utc_now()
    write_json_atomic(path, task)
    return {"task_id": task["task_id"], "status": "canceled"}


TOOL_HANDLERS: dict[str, Callable[[dict[str, Any]], Any]] = {
    "system_status": tool_system_status,
    "models_list": lambda _: {"models": load_models()},
    "repositories_list": lambda _: {"repositories": list_repositories()},
    "task_submit": tool_task_submit,
    "task_status": tool_task_status,
    "task_logs": tool_task_logs,
    "task_diff": tool_task_diff,
    "task_cancel": tool_task_cancel,
}


def response(request_id: Any, *, result: Any = None, error: dict[str, Any] | None = None) -> None:
    message: dict[str, Any] = {"jsonrpc": "2.0", "id": request_id}
    if error is not None:
        message["error"] = error
    else:
        message["result"] = result
    sys.stdout.write(json.dumps(message, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def handle(message: dict[str, Any]) -> None:
    method = message.get("method")
    if "id" not in message:
        return
    request_id = message["id"]
    params = message.get("params") or {}
    try:
        if method == "initialize":
            requested = params.get("protocolVersion")
            response(
                request_id,
                result={
                    "protocolVersion": requested if isinstance(requested, str) else DEFAULT_PROTOCOL,
                    "capabilities": {"tools": {"listChanged": False}},
                    "serverInfo": {"name": "alt-claude-slave", "version": SERVER_VERSION},
                    "instructions": "Executor local limitado. Liste repositorios antes de submeter tarefas. Toda tarefa deve declarar arquivos permitidos e deve ser revisada pelo planejador; o servidor nao cria commit nem faz merge.",
                },
            )
        elif method == "ping":
            response(request_id, result={})
        elif method == "tools/list":
            response(request_id, result={"tools": TOOLS})
        elif method == "tools/call":
            name = params.get("name")
            arguments = params.get("arguments") or {}
            if name not in TOOL_HANDLERS:
                raise ValueError(f"ferramenta desconhecida: {name}")
            if not isinstance(arguments, dict):
                raise ValueError("arguments deve ser um objeto")
            try:
                result = TOOL_HANDLERS[name](arguments)
                response(request_id, result=text_result(result))
            except (ValueError, OSError, subprocess.SubprocessError) as exc:
                response(request_id, result=text_result({"error": str(exc)}, error=True))
        else:
            response(request_id, error={"code": -32601, "message": f"Metodo nao encontrado: {method}"})
    except Exception as exc:  # keep the stdio server alive after malformed requests
        print(f"slave-mcp: {type(exc).__name__}: {exc}", file=sys.stderr, flush=True)
        response(request_id, error={"code": -32603, "message": "Erro interno do servidor"})


def main() -> int:
    ensure_state_dirs()
    for line in sys.stdin:
        try:
            message = json.loads(line)
            if not isinstance(message, dict):
                raise ValueError("mensagem JSON-RPC deve ser um objeto")
            handle(message)
        except (json.JSONDecodeError, ValueError) as exc:
            print(f"slave-mcp: mensagem invalida: {exc}", file=sys.stderr, flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
