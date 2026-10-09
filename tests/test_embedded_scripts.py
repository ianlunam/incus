"""Shell scripts embedded in task files (copy: content: "#!...") get no
other review - lint them as shell. shellcheck is used if installed, plain
`bash -n` / `sh -n` otherwise."""
import shutil
import subprocess

import jinja2
import pytest
import yaml


def _scripts(role):
    for p in sorted((role / "tasks").glob("*.yml")):
        for t in yaml.safe_load(p.read_text()) or []:
            content = (t.get("copy") or {}).get("content")
            if isinstance(content, str) and content.startswith("#!"):
                yield f"{p.name}:{t['name']}", content


def test_some_embedded_scripts_were_found(role):
    assert len(list(_scripts(role))) >= 2  # guards against the extractor silently finding none


def test_embedded_scripts_pass_shell_checks(role, tmp_path):
    env = jinja2.Environment(undefined=jinja2.DebugUndefined)  # unknown vars stay as {{ x }}
    failures = []
    for i, (label, content) in enumerate(_scripts(role)):
        rendered = env.from_string(content).render(
            esphome_backup_repo="git@example.com:x/y.git", ha_url="http://ha.test:8123"
        )
        shell = "bash" if rendered.startswith("#!/bin/bash") else "sh"
        f = tmp_path / f"s{i}.sh"
        f.write_text(rendered)
        for cmd in ([[shutil.which("shellcheck"), "-S", "warning", str(f)]] if shutil.which("shellcheck") else []) + [
            [shell, "-n", str(f)]
        ]:
            r = subprocess.run(cmd, capture_output=True, text=True)
            if r.returncode:
                failures.append(f"{label}\n{r.stdout}{r.stderr}")
    assert not failures, "\n\n".join(failures)


def test_shellcheck_availability_is_reported(request):
    if not shutil.which("shellcheck"):
        pytest.skip("shellcheck not installed - only `sh -n` syntax checks ran")
