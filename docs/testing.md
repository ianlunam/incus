# Checks and tests

Back to the [README](../README.md).

```
./check.sh            # everything (what CI runs)
./check.sh tests      # just pytest   (also: terraform | ansible | yaml)
```

Missing lint tools are fetched with `uvx` if you have it; otherwise that check
is skipped locally. In CI (`CI=true`) a skipped check counts as a failure, so
green CI means every check really ran. [`.github/workflows/check.yml`](../.github/workflows/check.yml)
runs `./check.sh` on pushes to `master` and on pull requests.

## What runs

| Check | Catches |
|---|---|
| `terraform fmt -check`, `init`, `validate` | formatting drift, undeclared variables, bad resource arguments |
| `ansible-playbook --syntax-check` | broken task files / imports |
| `ansible-lint` | unresolvable modules (e.g. a short name that only works through a redirect newer ansible-core drops), deprecated constructs. Style rules are skipped on purpose - see [`.ansible-lint`](../.ansible-lint) |
| `yamllint` | YAML mistakes ([`.yamllint`](../.yamllint)) |
| `pytest` ([`tests/`](../tests)) | everything below |

## The pytest suite

- **`test_repo_invariants.py`** - every instance pins a unique, valid MAC (HAOS is a
  documented exception); every task file is imported exactly once, named and
  tagged; task files parse as task lists; relative links in the markdown resolve.
- **`test_metrics_push.py`** - the incus-metrics-push script, rendered from its
  template and fed canned metrics. Includes regressions for two bugs actually hit on
  this host: VMs counting idle time as CPU use, and counter resets showing as
  huge negative percentages.
- **`test_embedded_scripts.py`** - shell scripts embedded in task files are
  syntax-checked, and run through `shellcheck` when it is installed.

## What is deliberately not tested here

Anything needing the real host: GPUs, ZFS, DKMS/reboot, the USB dongle, container
behaviour. That is verified by running the playbook against `incus-01` and reading
the recap - **`changed=0` on a re-run is the idempotency test.** A single area can
be re-run with `--tags` (see `tasks/main.yml`), e.g.
`ansible-playbook -i inventory/hosts.ini site.yml --tags rtl-sdr`.

## Adding to it

When a bug is found on the host, add the smallest test that would have caught it
(a fixture in `test_metrics_push.py`, or an invariant in `test_repo_invariants.py`)
alongside the fix. Run `./check.sh` before pushing.
