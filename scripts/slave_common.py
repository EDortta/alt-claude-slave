"""Shared, dependency-free helpers for alt-claude-slave."""

from __future__ import annotations

import json
import os
import re
import tempfile
from pathlib import Path, PurePosixPath
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parent.parent
STATE_DIR = Path(os.environ.get("SLAVE_STATE_DIR", "/srv/alt-claude/state"))
REPOS_DIR = Path(os.environ.get("SLAVE_REPOS_DIR", "/srv/alt-claude/repos"))
MODELS_FILE = Path(os.environ.get("SLAVE_MODELS_FILE", PROJECT_ROOT / "config/models.tsv"))
LLAMA_BIN = Path(os.environ.get("LLAMA_BIN", Path.home() / ".local/opt/llama.cpp/bin"))

SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
SAFE_REF = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,191}$")
SAFE_TASK_ID = re.compile(r"^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$")


def ensure_state_dirs() -> None:
    for path in (STATE_DIR, STATE_DIR / "tasks", STATE_DIR / "worktrees"):
        path.mkdir(parents=True, exist_ok=True)


def task_file(task_id: str) -> Path:
    if not SAFE_TASK_ID.fullmatch(task_id):
        raise ValueError("task_id invalido")
    return STATE_DIR / "tasks" / f"{task_id}.json"


def read_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"JSON invalido: {path}")
    return value


def write_json_atomic(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def validate_repository(name: str) -> Path:
    if not SAFE_NAME.fullmatch(name):
        raise ValueError("repository deve ser somente o nome do diretorio")
    path = REPOS_DIR / name
    if not path.is_dir() or not (path / ".git").exists():
        raise ValueError(f"repositorio Git nao encontrado: {name}")
    return path


def validate_ref(value: str) -> str:
    if not SAFE_REF.fullmatch(value) or ".." in value or value.endswith("/"):
        raise ValueError("base_branch invalida")
    return value


def validate_allowed_files(values: Any) -> list[str]:
    if not isinstance(values, list) or not values or len(values) > 40:
        raise ValueError("allowed_files deve conter entre 1 e 40 caminhos")
    normalized: list[str] = []
    for value in values:
        if not isinstance(value, str) or not value or len(value) > 240:
            raise ValueError("caminho permitido invalido")
        path = PurePosixPath(value)
        if path.is_absolute() or ".." in path.parts or ".git" in path.parts:
            raise ValueError(f"caminho fora do repositorio: {value}")
        item = path.as_posix()
        if item in ("", "."):
            raise ValueError("diretorio raiz nao pode ser um arquivo permitido")
        normalized.append(item)
    return sorted(set(normalized))


def validate_test_commands(values: Any) -> list[str]:
    if not isinstance(values, list) or len(values) > 8:
        raise ValueError("no maximo 8 comandos de teste")
    commands: list[str] = []
    for value in values:
        if not isinstance(value, str) or not value or len(value) > 500:
            raise ValueError("comando de teste invalido")
        if "\n" in value or "\r" in value or "\x00" in value:
            raise ValueError("comando de teste deve ocupar uma unica linha")
        commands.append(value)
    return commands


def load_models() -> list[dict[str, Any]]:
    models: list[dict[str, Any]] = []
    with MODELS_FILE.open("r", encoding="utf-8") as handle:
        for line in handle:
            if not line.strip() or line.startswith("#"):
                continue
            fields = line.rstrip("\n").split("|")
            if len(fields) != 7:
                raise ValueError(f"linha invalida no catalogo: {line.rstrip()}")
            model_id, repository, quant, context, threads, status, purpose = fields
            models.append(
                {
                    "id": model_id,
                    "repository": repository,
                    "quant": quant,
                    "context": int(context),
                    "threads": int(threads),
                    "status": status,
                    "purpose": purpose,
                }
            )
    return models


def get_model(model_id: str) -> dict[str, Any]:
    for model in load_models():
        if model["id"] == model_id:
            return model
    raise ValueError(f"perfil de modelo desconhecido: {model_id}")


def list_repositories() -> list[dict[str, str]]:
    if not REPOS_DIR.exists():
        return []
    repositories: list[dict[str, str]] = []
    for path in sorted(REPOS_DIR.iterdir()):
        if path.is_dir() and (path / ".git").exists():
            repositories.append({"name": path.name, "path": str(path)})
    return repositories
