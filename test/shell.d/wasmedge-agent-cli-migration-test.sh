#!/bin/bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

migration="$ROOT/migrations/1789203927.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

home="$tmpdir/home"
mkdir -p "$home/.local/bin" "$home/.local/state/omarchy"

marker="# Written by omarchy-install-wasmedge-agent."
launcher="$home/.local/bin/wasmedge-agent"

# The real command is on PATH, so the migration writes today's launcher rather
# than a copy of it that can drift.
run_migration() {
  env "HOME=$home" "PATH=$ROOT/bin:/usr/bin:/bin" bash -euo pipefail "$migration"
}

[[ -f $migration ]] || fail "the migration file exists"
[[ $(stat -c %a "$migration") == "644" ]] ||
  fail "the migration is mode 0644" "mode: $(stat -c %a "$migration")"
[[ $(head -1 "$migration") != "#!"* ]] ||
  fail "the migration has no shebang" "$(head -1 "$migration")"
pass "the migration has the shape omarchy-migrate expects"

run_migration >/dev/null || fail "the migration runs on a plain install"
[[ -x $launcher ]] && grep -qxF "$marker" "$launcher" ||
  fail "the migration writes the Omarchy launcher"
pass "the migration installs the launcher"

before=$(cat "$launcher")
run_migration >/dev/null || fail "rerunning the migration succeeds"
[[ $(cat "$launcher") == "$before" ]] || fail "rerunning the migration leaves the same launcher"
pass "the migration is idempotent"

chmod -x "$launcher"
run_migration >/dev/null || fail "the migration repairs a launcher that lost its executable bit"
[[ -x $launcher ]] || fail "the migration restores the executable bit"
[[ $(cat "$launcher") == "$before" ]] ||
  fail "the migration restores the launcher content, not just its executable bit"
pass "the migration repairs a non-executable launcher"

rm -f "$launcher"
touch "$home/.local/state/omarchy/preinstalls-removed"
run_migration >/dev/null || fail "the migration succeeds for users who removed the preinstalls"
[[ ! -e $launcher ]] || fail "the migration respects the preinstalls opt-out"
pass "the migration skips users who removed the preinstalls"
rm -f "$home/.local/state/omarchy/preinstalls-removed"

foreign_body='#!/bin/bash
echo mine'
printf '%s\n' "$foreign_body" >"$launcher"
chmod +x "$launcher"
run_migration >/dev/null || fail "the migration succeeds with a foreign launcher"
[[ $(cat "$launcher") == "$foreign_body" ]] || fail "the migration leaves a foreign launcher alone"
pass "the migration leaves a launcher the user wrote alone"

# The `|| true` on the command. omarchy-migrate runs this under its own `set -e`,
# so a migration that exits non-zero aborts the run: every later migration then
# neither runs nor gets its completion marker.
failing_bin="$tmpdir/failing-bin"
mkdir -p "$failing_bin"
printf '%s\n' "#!/bin/bash" "exit 1" >"$failing_bin/omarchy-install-wasmedge-agent"
chmod +x "$failing_bin/omarchy-install-wasmedge-agent"
env "HOME=$home" "PATH=$failing_bin:$ROOT/bin:/usr/bin:/bin" bash -euo pipefail "$migration" >/dev/null ||
  fail "the migration exits 0 when the command it calls fails"
pass "a failing command does not abort the migration"

# The other half of the seeding: a machine installed from the ISO gets the
# launcher at provision time, not at its first update. A grep for the line's
# text alone would still pass on dead code -- the line moved after an earlier
# `return`, say -- so install/user/mise.sh is sourced end to end and the effect
# is checked, the way test/shell.d/hermes-cli-test.sh already sources this same
# file for the same reason.
grep -qxF "omarchy-install-wasmedge-agent || true" "$ROOT/install/user/mise.sh" ||
  fail "the new-user install path seeds the launcher"

mise_sh_home="$tmpdir/mise-sh-home"
mise_sh_bin="$tmpdir/mise-sh-bin"
mkdir -p "$mise_sh_home/.local/bin" "$mise_sh_bin"

# The only external command install/user/mise.sh calls directly rather than
# through a lazy stub it writes for later use. Stubbed so the file can run to
# its end without a real mise on PATH.
cat >"$mise_sh_bin/mise" <<'SH'
#!/bin/bash
[[ $1 != "where" ]]
SH
chmod +x "$mise_sh_bin/mise"

env "HOME=$mise_sh_home" "PATH=$mise_sh_bin:$ROOT/bin:/usr/bin:/bin" \
  bash -eE -c 'source "$1"' bash "$ROOT/install/user/mise.sh" >/dev/null 2>&1 ||
  fail "install/user/mise.sh runs to its end"
[[ -x $mise_sh_home/.local/bin/wasmedge-agent ]] &&
  grep -qxF "$marker" "$mise_sh_home/.local/bin/wasmedge-agent" ||
  fail "the new-user install path seeds the launcher"
pass "the new-user install path seeds the launcher"
