#!/usr/bin/env python3

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


class SlaveMcpIntegrationTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        self.state = root / "state"
        self.repos = root / "repos"
        self.bin = root / "bin"
        self.repos.mkdir()
        self.bin.mkdir()

        repository = self.repos / "sample"
        repository.mkdir()
        subprocess.run(["git", "init", "-b", "main"], cwd=repository, check=True, capture_output=True)
        subprocess.run(["git", "config", "user.name", "Test"], cwd=repository, check=True)
        subprocess.run(["git", "config", "user.email", "test@example.invalid"], cwd=repository, check=True)
        (repository / "hello.py").write_text('MESSAGE = "old"\n', encoding="utf-8")
        subprocess.run(["git", "add", "hello.py"], cwd=repository, check=True)
        subprocess.run(["git", "commit", "-m", "initial"], cwd=repository, check=True, capture_output=True)

        fake_llama = self.bin / "llama-cli"
        fake_llama.write_text(
            "#!/usr/bin/env bash\n"
            "cat <<'PATCH'\n"
            "diff --git a/hello.py b/hello.py\n"
            "--- a/hello.py\n"
            "+++ b/hello.py\n"
            "@@ -1 +1 @@\n"
            "-MESSAGE = \"old\"\n"
            "+MESSAGE = \"new\"\n"
            "PATCH\n",
            encoding="utf-8",
        )
        fake_llama.chmod(0o755)

        self.environment = os.environ.copy()
        self.environment.update(
            {
                "SLAVE_STATE_DIR": str(self.state),
                "SLAVE_REPOS_DIR": str(self.repos),
                "SLAVE_MODELS_FILE": str(ROOT / "config/models.tsv"),
                "LLAMA_BIN": str(self.bin),
            }
        )
        self.server = subprocess.Popen(
            [str(ROOT / "slave-mcp")],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=self.environment,
        )

    def tearDown(self) -> None:
        self.server.terminate()
        self.server.wait(timeout=5)
        for stream in (self.server.stdin, self.server.stdout, self.server.stderr):
            if stream is not None:
                stream.close()
        self.temporary.cleanup()

    def request(self, request_id: int, method: str, params: dict | None = None) -> dict:
        assert self.server.stdin is not None
        assert self.server.stdout is not None
        message = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None:
            message["params"] = params
        self.server.stdin.write(json.dumps(message) + "\n")
        self.server.stdin.flush()
        response = json.loads(self.server.stdout.readline())
        self.assertEqual(request_id, response["id"])
        return response

    def test_protocol_and_task_execution(self) -> None:
        initialized = self.request(1, "initialize", {"protocolVersion": "2026-07-28", "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}})
        self.assertEqual("alt-claude-slave", initialized["result"]["serverInfo"]["name"])

        tools = self.request(2, "tools/list")["result"]["tools"]
        self.assertIn("task_submit", {tool["name"] for tool in tools})

        repositories = self.request(3, "tools/call", {"name": "repositories_list", "arguments": {}})
        structured = repositories["result"]["structuredContent"]
        self.assertEqual("sample", structured["repositories"][0]["name"])

        submitted = self.request(
            4,
            "tools/call",
            {
                "name": "task_submit",
                "arguments": {
                    "repository": "sample",
                    "objective": "Troque a mensagem antiga pela nova.",
                    "allowed_files": ["hello.py"],
                    "test_commands": ["python3 -m py_compile hello.py"],
                },
            },
        )
        task_id = submitted["result"]["structuredContent"]["task_id"]

        status = "queued"
        task = {}
        for _ in range(100):
            task = json.loads((self.state / "tasks" / f"{task_id}.json").read_text(encoding="utf-8"))
            status = task["status"]
            if status in {"succeeded", "failed", "canceled"}:
                break
            time.sleep(0.05)
        self.assertEqual("succeeded", status, task)
        self.assertEqual(["hello.py"], task["changed_files"])

        diff_response = self.request(5, "tools/call", {"name": "task_diff", "arguments": {"task_id": task_id}})
        diff = diff_response["result"]["structuredContent"]["diff"]
        self.assertIn('+MESSAGE = "new"', diff)


if __name__ == "__main__":
    unittest.main()
