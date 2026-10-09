"""incus-metrics-push is the one piece of real logic in this repo.

Rendered from its Jinja template and exercised with canned metrics. Several
cases are regressions for bugs that were actually seen on this host (see the
comments in the script itself).
"""
import json
import types
import urllib.error

import jinja2
import pytest


@pytest.fixture
def mod(role, tmp_path, monkeypatch):
    src = (role / "templates" / "incus-metrics-push.py.j2").read_text()
    code = jinja2.Template(src, undefined=jinja2.StrictUndefined).render(ha_url="http://ha.test:8123")
    m = types.ModuleType("metrics_push")
    exec(compile(code, "incus-metrics-push.py", "exec"), m.__dict__)
    token = tmp_path / "ha_token"
    token.write_text("secret-token\n")
    monkeypatch.setattr(m, "TOKEN_FILE", str(token))
    monkeypatch.setattr(m, "STATE_FILE", str(tmp_path / "state.json"))
    m.pushed = {}
    monkeypatch.setattr(m, "push_state", lambda tok, eid, state, attrs: m.pushed.__setitem__(eid, (state, attrs, tok)))
    return m


def metrics(**per_instance):
    """Build Prometheus-style text from {instance: {metric: value}}."""
    lines = ["# HELP incus_memory_Active_bytes demo", "# TYPE incus_memory_Active_bytes gauge"]
    for inst, ms in per_instance.items():
        for metric, value in ms.items():
            lines.append(f'{metric}{{name="{inst}",project="default",type="container"}} {value}')
    return "\n".join(lines) + "\n"


def run(mod, monkeypatch, text, now):
    mod.pushed.clear()
    monkeypatch.setattr(mod, "get_metrics_text", lambda: text)
    monkeypatch.setattr(mod.time, "time", lambda: now)
    mod.main()
    return dict(mod.pushed)


MIB = 1024 * 1024


# --- parse_metrics -----------------------------------------------------------
def test_parse_sums_across_other_labels(mod):
    text = (
        'incus_cpu_seconds_total{name="a",mode="user",cpu="0"} 10\n'
        'incus_cpu_seconds_total{name="a",mode="system",cpu="1"} 5.5\n'
    )
    assert mod.parse_metrics(text) == {"a": {"incus_cpu_seconds_total": 15.5}}


def test_parse_skips_comments_blank_lines_and_unlabelled_series(mod):
    text = '# TYPE x counter\n\nincus_uptime_seconds 99\nincus_memory_Active_bytes{name="a"} 7\n'
    assert mod.parse_metrics(text) == {"a": {"incus_memory_Active_bytes": 7.0}}


def test_parse_excludes_idle_and_iowait(mod):
    # Regression: a 2-vCPU VM idling used to read ~200% busy because "idle"
    # seconds were summed into "CPU actually used".
    text = "\n".join(
        f'incus_cpu_seconds_total{{name="vm",mode="{m}",cpu="0"}} {v}'
        for m, v in [("user", 3), ("system", 2), ("idle", 1000), ("iowait", 50), ("steal", 1)]
    )
    assert mod.parse_metrics(text) == {"vm": {"incus_cpu_seconds_total": 6.0}}


# --- main(): memory and CPU --------------------------------------------------
def test_first_run_pushes_memory_only_and_saves_state(mod, monkeypatch, tmp_path):
    text = metrics(web={"incus_memory_Active_bytes": 100 * MIB, "incus_cpu_seconds_total": 5})
    pushed = run(mod, monkeypatch, text, now=1000.0)
    assert set(pushed) == {"sensor.incus_web_memory"}  # no previous sample -> no CPU yet
    assert pushed["sensor.incus_web_memory"][0] == 100.0
    saved = json.loads((tmp_path / "state.json").read_text())
    assert saved["timestamp"] == 1000.0 and "web" in saved["instances"]


def test_cpu_percent_from_delta_over_elapsed(mod, monkeypatch):
    t1 = metrics(web={"incus_memory_Active_bytes": MIB, "incus_cpu_seconds_total": 100})
    t2 = metrics(web={"incus_memory_Active_bytes": MIB, "incus_cpu_seconds_total": 130})
    run(mod, monkeypatch, t1, now=1000.0)
    pushed = run(mod, monkeypatch, t2, now=1060.0)  # 30 cpu-seconds in 60s
    assert pushed["sensor.incus_web_cpu"][0] == 50.0


def test_multicore_usage_can_exceed_100(mod, monkeypatch):
    run(mod, monkeypatch, metrics(w={"incus_cpu_seconds_total": 0}), now=0.0)
    pushed = run(mod, monkeypatch, metrics(w={"incus_cpu_seconds_total": 120}), now=60.0)
    assert pushed["sensor.incus_w_cpu"][0] == 200.0


def test_counter_reset_on_restart_is_not_negative(mod, monkeypatch):
    # Regression: an instance restart dropped the cumulative counter and the
    # sensor showed -258,071.5% for Frigate.
    run(mod, monkeypatch, metrics(f={"incus_cpu_seconds_total": 500000}), now=1000.0)
    pushed = run(mod, monkeypatch, metrics(f={"incus_cpu_seconds_total": 6}), now=1060.0)
    assert pushed["sensor.incus_f_cpu"][0] == 10.0  # 6s used since restart / 60s


def test_instance_created_since_last_run_gets_no_cpu_sample(mod, monkeypatch):
    run(mod, monkeypatch, metrics(old={"incus_cpu_seconds_total": 1}), now=0.0)
    pushed = run(mod, monkeypatch, metrics(old={"incus_cpu_seconds_total": 2}, new={"incus_cpu_seconds_total": 9}), now=60.0)
    assert "sensor.incus_old_cpu" in pushed and "sensor.incus_new_cpu" not in pushed


def test_zero_elapsed_does_not_divide_by_zero(mod, monkeypatch):
    run(mod, monkeypatch, metrics(a={"incus_cpu_seconds_total": 1}), now=100.0)
    pushed = run(mod, monkeypatch, metrics(a={"incus_cpu_seconds_total": 5}), now=100.0)
    assert pushed["sensor.incus_a_cpu"][0] == 0.0


def test_hyphens_in_instance_names_become_underscores(mod, monkeypatch):
    pushed = run(mod, monkeypatch, metrics(**{"matter-server": {"incus_memory_Active_bytes": MIB}}), now=0.0)
    assert "sensor.incus_matter_server_memory" in pushed


def test_token_is_stripped_and_sent(mod, monkeypatch):
    pushed = run(mod, monkeypatch, metrics(a={"incus_memory_Active_bytes": MIB}), now=0.0)
    assert pushed["sensor.incus_a_memory"][2] == "secret-token"


def test_unreachable_ha_does_not_abort_the_run(mod, monkeypatch, tmp_path, capsys):
    def boom(*a, **k):
        raise urllib.error.URLError("ha is down")

    monkeypatch.setattr(mod, "push_state", boom)
    monkeypatch.setattr(mod, "get_metrics_text", lambda: metrics(a={"incus_memory_Active_bytes": MIB}))
    monkeypatch.setattr(mod.time, "time", lambda: 5.0)
    mod.main()  # must not raise
    assert "Failed to push memory for a" in capsys.readouterr().out
    assert (tmp_path / "state.json").exists()  # state still saved so CPU resumes next time


def test_corrupt_state_file_is_treated_as_first_run(mod, monkeypatch, tmp_path):
    (tmp_path / "state.json").write_text("{not json")
    pushed = run(mod, monkeypatch, metrics(a={"incus_memory_Active_bytes": MIB}), now=0.0)
    assert set(pushed) == {"sensor.incus_a_memory"}
