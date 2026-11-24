"""The Frigate config.yml template, rendered with the real group_vars."""
import re

import jinja2
import pytest
import yaml


@pytest.fixture(scope="module")
def rendered(role, root):
    env = jinja2.Environment(undefined=jinja2.StrictUndefined)
    ctx = yaml.safe_load((root / "ansible" / "group_vars" / "all.yml").read_text())
    # group_vars values can reference each other ("{{ bridge_ip }}") - resolve them.
    for _ in range(3):
        ctx = {k: env.from_string(v).render(ctx) if isinstance(v, str) else v for k, v in ctx.items()}
    text = env.from_string((role / "templates" / "frigate-config.yml.j2").read_text()).render(ctx)
    return ctx, text, yaml.safe_load(text)


def test_renders_to_valid_yaml_with_every_camera(rendered):
    ctx, _, cfg = rendered
    assert sorted(cfg["cameras"]) == sorted(c["name"] for c in ctx["frigate_cameras"])


def test_mqtt_block_present(rendered):
    # Without it Frigate silently falls into safe mode and ignores the cameras.
    assert rendered[2]["mqtt"]["host"]


def test_no_token_is_committed(rendered):
    _, text, cfg = rendered
    assert not re.search(r"eyJ[A-Za-z0-9_-]{10,}", text), "looks like a JWT in the rendered config"
    for cam in cfg["cameras"].values():
        args = cam["ffmpeg"]["inputs"][0]["input_args"]
        assert "Authorization: Bearer {FRIGATE_HA_TOKEN}" in args


def test_model_size_follows_the_var(rendered):
    ctx, _, cfg = rendered
    assert cfg["model"]["width"] == cfg["model"]["height"] == ctx["frigate_model_size"]


def test_custom_record_args_keep_the_required_segment_flags(rendered):
    # Frigate refuses to start without these when record args are overridden.
    for cam in rendered[2]["cameras"].values():
        rec = cam["ffmpeg"]["output_args"]["record"]
        assert "-f segment" in rec and "-segment_format mp4" in rec and "-strftime 1" in rec


def test_every_env_placeholder_is_set_on_the_instance(role, root):
    # An unset {FRIGATE_*} variable makes Frigate fail config validation.
    placeholders = set(re.findall(r"\{(FRIGATE_[A-Z0-9_]+)\}", (role / "templates" / "frigate-config.yml.j2").read_text()))
    tf = (root / "terraform" / "frigate.tf").read_text()
    missing = {p for p in placeholders if f'"environment.{p}"' not in tf}
    assert placeholders and not missing, f"not set in frigate.tf: {missing}"
