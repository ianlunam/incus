"""Rules this repo has already had to learn the hard way, enforced cheaply."""
import re

import yaml


def _instances(root):
    """Yield (file, resource name, block text) for every incus_instance."""
    for tf in sorted((root / "terraform").glob("*.tf")):
        text = tf.read_text()
        for m in re.finditer(r'^resource "incus_instance" "([^"]+)"', text, re.M):
            rest = text[m.end():]
            nxt = re.search(r"^resource ", rest, re.M)
            yield tf.name, m.group(1), rest[: nxt.start()] if nxt else rest


def _hwaddrs(block):
    code = "\n".join(l for l in block.splitlines() if not l.lstrip().startswith("#"))
    return re.findall(r'hwaddr\s*=\s*"([^"]+)"', code)


# haos is deliberately unpinned: touching its NIC device fails ("Failed to
# detach NIC") and drops the VM off the LAN - see the note in haos.tf. Its MAC
# only changes if the VM is recreated, at which point pin it.
UNPINNED_ON_PURPOSE = {"haos"}


def test_every_instance_pins_a_mac(root):
    # Incus otherwise invents a new random MAC on every recreate, which
    # orphans the router-side DHCP reservation (and HA/Frigate's address for it).
    missing = [f"{f}:{n}" for f, n, b in _instances(root) if not _hwaddrs(b) and n not in UNPINNED_ON_PURPOSE]
    assert not missing, f"instances without a pinned hwaddr: {missing}"


def test_pinned_macs_are_valid_and_unique(root):
    seen = {}
    for f, n, b in _instances(root):
        for mac in _hwaddrs(b):
            assert re.fullmatch(r"([0-9a-f]{2}:){5}[0-9a-f]{2}", mac), f"{f}:{n} bad MAC {mac!r}"
            assert mac not in seen, f"{mac} used by both {seen[mac]} and {f}:{n}"
            seen[mac] = f"{f}:{n}"
    assert seen, "found no instances at all - is the parser broken?"


def _main_imports(role):
    tasks = yaml.safe_load((role / "tasks" / "main.yml").read_text())
    return [t for t in tasks if "import_tasks" in t]


def test_every_task_file_is_imported_exactly_once(role):
    imported = [t["import_tasks"] for t in _main_imports(role)]
    on_disk = sorted(p.name for p in (role / "tasks").glob("*.yml") if p.name != "main.yml")
    assert sorted(imported) == on_disk, "tasks/ and main.yml's imports disagree"


def test_imports_are_named_and_tagged_uniquely(role):
    imports = _main_imports(role)
    for t in imports:
        assert t.get("name"), f"{t['import_tasks']} has no name"
        assert t.get("tags"), f"{t['import_tasks']} has no tag (--tags <area> relies on it)"
    tags = [tag for t in imports for tag in t["tags"]]
    assert len(tags) == len(set(tags)), f"duplicate tags: {sorted(tags)}"


def test_task_files_parse_as_task_lists(role):
    for p in (role / "tasks").glob("*.yml"):
        data = yaml.safe_load(p.read_text())
        assert isinstance(data, list) and data, f"{p.name} is not a non-empty task list"
        for t in data:
            assert isinstance(t, dict) and ("name" in t or "import_tasks" in t), (
                f"{p.name}: unnamed task {t!r:.80}"
            )


def test_markdown_relative_links_resolve(root):
    bad = []
    for md in [root / "README.md", *sorted((root / "docs").glob("*.md"))]:
        for target in re.findall(r"\]\(([^)\s]+)\)", md.read_text()):
            if re.match(r"[a-z]+:", target) or target.startswith("#"):
                continue  # external URL or in-page anchor
            path = (md.parent / target.split("#")[0]).resolve()
            if not path.exists():
                bad.append(f"{md.relative_to(root)} -> {target}")
    assert not bad, f"broken links: {bad}"
