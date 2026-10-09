#!/usr/bin/env bash
# Static checks + unit tests. Run before pushing; CI runs exactly this.
#
#   ./check.sh            run everything
#   ./check.sh tests      only the pytest suite   (also: terraform | ansible | yaml)
#
# Needs: terraform, ansible, python3. Lint tools (ansible-lint, yamllint,
# pytest) are used from PATH if present, otherwise fetched on the fly with
# `uvx`. A check whose tool can't be found is SKIPPED locally but FAILS in CI
# (CI=true), so a green CI run always means everything really ran.
set -uo pipefail
cd "$(dirname "$0")"

only="${1:-all}"
failed=0
skipped=0

run() { # run <label> <cmd...>
  local label=$1; shift
  printf '\n==> %s\n' "$label"
  if "$@"; then echo "    ok"; else echo "    FAILED: $label"; failed=$((failed + 1)); fi
}
want() { [[ $only == all || $only == "$1" ]]; }

# Prefer a tool on PATH, else uvx (--from/--with allowed via TOOL_PKG), else skip.
have() { command -v "$1" >/dev/null 2>&1; }
missing() {
  printf '\n==> %s\n    SKIPPED: %s not found (install it or uv)\n' "$1" "$2"
  skipped=$((skipped + 1))
}
uvrun() { have uvx && uvx --quiet "$@"; }

if want terraform; then
  if have terraform; then
    run "terraform fmt -check"  terraform -chdir=terraform fmt -check -diff
    run "terraform init+validate" bash -c \
      'terraform -chdir=terraform init -backend=false -input=false >/dev/null && terraform -chdir=terraform validate'
  else missing "terraform checks" terraform; fi
fi

if want ansible; then
  export ANSIBLE_COLLECTIONS_PATH="$PWD/.cache/ansible-collections"
  if have ansible-galaxy && have ansible-playbook; then
    # --force: galaxy otherwise sees the system-wide copies and installs nothing
    # into .cache, which ansible-lint's own isolated ansible-core can't see.
    if [[ ! -d .cache/ansible-collections/ansible_collections/ansible/posix ]]; then
      run "install ansible collections" ansible-galaxy collection install --force -r ansible/requirements.yml -p .cache/ansible-collections
    fi
    run "ansible syntax-check" bash -c 'cd ansible && ansible-playbook -i inventory/hosts.ini site.yml --syntax-check >/dev/null'
  else missing "ansible syntax-check" ansible; fi
  if have ansible-lint; then run "ansible-lint" bash -c 'cd ansible && ansible-lint --offline site.yml'
  elif have uvx;        then run "ansible-lint (uvx)" bash -c 'cd ansible && uvx --quiet ansible-lint --offline site.yml'
  else missing "ansible-lint" ansible-lint; fi
fi

if want yaml; then
  if have yamllint; then run "yamllint" yamllint -c .yamllint ansible .github
  elif have uvx;    then run "yamllint (uvx)" uvx --quiet yamllint -c .yamllint ansible .github
  else missing "yamllint" yamllint; fi
fi

if want tests; then
  if python3 -c 'import pytest, jinja2, yaml' 2>/dev/null; then run "pytest" python3 -m pytest -q tests
  elif have uvx; then run "pytest (uvx)" uvx --quiet --with-requirements tests/requirements.txt pytest -q tests
  else missing "pytest" "pytest/jinja2/pyyaml"; fi
fi

printf '\n'
if [[ $failed -gt 0 ]]; then echo "$failed check(s) FAILED"; exit 1; fi
if [[ $skipped -gt 0 && -n ${CI:-} ]]; then echo "$skipped check(s) skipped in CI - treating as failure"; exit 1; fi
echo "all checks passed${skipped:+ ($skipped skipped)}"
