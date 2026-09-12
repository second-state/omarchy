#!/bin/bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

# jq is the real parser the command uses, and it is in omarchy-base.packages.
# Stubbing it would test the stub.
require_command jq

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

home="$tmpdir/home"
stub_bin="$tmpdir/bin"
agent_bin="$tmpdir/agent-bin"
npm_prefix="$tmpdir/npm-prefix"
curl_log="$tmpdir/curl.log"
mkdir -p "$home/.local/bin" "$stub_bin" "$agent_bin"

command_under_test="$ROOT/bin/omarchy-install-wasmedge-agent"
marker="# Written by omarchy-install-wasmedge-agent."
launcher="$home/.local/bin/wasmedge-agent"

# Stands in for the installed agent. It records its arguments one per NUL, so a
# test can prove the launcher passed them through without splitting or
# evaluating them.
cat >"$agent_bin/wasmedge-agent" <<'SH'
#!/bin/bash

printf '%s\0' "$@" >>"${OMARCHY_TEST_AGENT_LOG:-/dev/null}"

case "${1:-}" in
  --version)
    echo "wasmedge-agent 0.0.1-test"
    ;;
  doctor)
    cat "$OMARCHY_TEST_DOCTOR_JSON"
    ;;
esac
SH

# npm answers where a global install would land. The directory exists only when a
# test makes it, so the fallback in the resolution rule is exercised both ways.
cat >"$stub_bin/npm" <<'SH'
#!/bin/bash

if [[ ${1:-} == "prefix" && ${2:-} == "-g" ]]; then
  printf '%s\n' "$OMARCHY_TEST_NPM_PREFIX"
fi
SH

# Records what was asked for, then delivers the fake installer to the -o path, so
# a test can assert both the URL and that nothing was downloaded at all.
cat >"$stub_bin/curl" <<'SH'
#!/bin/bash

printf '%s\0' "$@" >>"$OMARCHY_TEST_CURL_LOG"

output=
while (($#)); do
  case "$1" in
    -o)
      output=$2
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ ${OMARCHY_TEST_CURL_FAILS:-0} == 1 ]]; then
  exit 22
fi

[[ -n $output ]] || exit 1
cp "$OMARCHY_TEST_INSTALLER" "$output"
SH

# Stands in for the agent's published install.sh: it records how it was called
# and, on success, leaves an agent where npm says a global install lands.
cat >"$tmpdir/fake-installer" <<'SH'
#!/bin/sh

printf 'installer ran: %s\n' "$*" >>"$OMARCHY_TEST_INSTALLER_LOG"

if [ "${OMARCHY_TEST_INSTALLER_FAILS:-0}" = "1" ]; then
  printf 'installer failed\n'
  exit 1
fi

module_dir="$OMARCHY_TEST_NPM_PREFIX/lib/node_modules/wasmedge-agent"
mkdir -p "$OMARCHY_TEST_NPM_PREFIX/bin" "$module_dir"
module="$module_dir/cli.js"
target="$OMARCHY_TEST_NPM_PREFIX/bin/wasmedge-agent"

cp "$OMARCHY_TEST_AGENT_SOURCE" "$module"
chmod 755 "$module"

# The real installer ends in `npm install -g`, and npm creates the package's
# command in the global prefix's bin directory -- as a symbolic link into its
# own module tree, which is what tells npm's command apart from a file somebody
# else put at that name. npm refuses when a path it does not already own holds
# the name -- `npm error code EEXIST`, exit 1 -- and replaces its own link
# without complaint. An installer that copies a plain file over whatever it
# finds hides both halves of that, and the one arrangement where they bite: a
# global prefix of ~/.local, where the path npm needs is the launcher's own.
if [ -e "$target" ] || [ -L "$target" ]; then
  if [ "$(realpath "$target" 2>/dev/null)" != "$(realpath "$module")" ]; then
    printf 'npm error code EEXIST\n'
    printf 'npm error path %s\n' "$target"
    printf 'npm error EEXIST: file already exists\n'
    printf 'npm error Remove the existing file and try again, or run npm\n'
    printf 'npm error with --force to overwrite files recklessly.\n'
    exit 1
  fi
fi

ln -sfT "../lib/node_modules/wasmedge-agent/cli.js" "$target"
SH

chmod +x "$agent_bin/wasmedge-agent" "$stub_bin/npm" "$stub_bin/curl" "$tmpdir/fake-installer"

printf '%s' '{"runtime":[{"name":"cargo","ok":true,"detail":"1.0"},{"name":"wasmedge","ok":true,"detail":"0.15"}]}' >"$tmpdir/doctor-ok.json"
printf '%s' '{"runtime":[{"name":"cargo","ok":true,"detail":"1.0"},{"name":"wasmedge","ok":false,"detail":"missing"}]}' >"$tmpdir/doctor-bad.json"
printf '%s' '{"runtime":[]}' >"$tmpdir/doctor-empty.json"

# Nothing on PATH but the stubs and the system tools, so a wasmedge-agent
# installed on the machine running the suite cannot answer for the one under
# test. Individual tests prepend directories to model a real PATH.
base_path="$stub_bin:/usr/bin:/bin"

build_test_env() {
  test_env=(
    "HOME=$home"
    "PATH=${OMARCHY_TEST_PATH:-$base_path}"
    "OMARCHY_TEST_AGENT_LOG=${OMARCHY_TEST_AGENT_LOG:-$tmpdir/agent.log}"
    "OMARCHY_TEST_AGENT_SOURCE=$agent_bin/wasmedge-agent"
    "OMARCHY_TEST_CURL_LOG=${OMARCHY_TEST_CURL_LOG:-$curl_log}"
    "OMARCHY_TEST_CURL_FAILS=${OMARCHY_TEST_CURL_FAILS:-0}"
    "OMARCHY_TEST_DOCTOR_JSON=${OMARCHY_TEST_DOCTOR_JSON:-$tmpdir/doctor-ok.json}"
    "OMARCHY_TEST_INSTALLER=$tmpdir/fake-installer"
    "OMARCHY_TEST_INSTALLER_FAILS=${OMARCHY_TEST_INSTALLER_FAILS:-0}"
    "OMARCHY_TEST_INSTALLER_LOG=${OMARCHY_TEST_INSTALLER_LOG:-$tmpdir/installer.log}"
    "OMARCHY_TEST_NPM_PREFIX=${OMARCHY_TEST_NPM_PREFIX:-$npm_prefix}"
  )

  if [[ -n ${OMARCHY_WASMEDGE_AGENT_INSTALLER_URL:-} ]]; then
    test_env+=("OMARCHY_WASMEDGE_AGENT_INSTALLER_URL=$OMARCHY_WASMEDGE_AGENT_INSTALLER_URL")
  fi
}

run() {
  build_test_env
  env "${test_env[@]}" "$command_under_test" "$@"
}

run_launcher() {
  build_test_env
  env "${test_env[@]}" "$launcher" "$@"
}

# --- Task 1: the read-only modes -------------------------------------------

# --owns and --check are questions. Neither may create the launcher.
if run --owns; then
  fail "--owns answers no when nothing is at the launcher path"
fi
[[ ! -e $launcher ]] || fail "--owns creates no launcher"
pass "--owns answers no when nothing is at the launcher path"

printf '%s\n' "#!/bin/bash" "$marker" >"$launcher"
chmod +x "$launcher"
run --owns || fail "--owns recognises a launcher Omarchy wrote"
pass "--owns recognises a launcher Omarchy wrote"

printf '%s\n' "#!/bin/bash" "echo mine" >"$launcher"
chmod +x "$launcher"
if run --owns; then
  fail "--owns rejects a file Omarchy did not write"
fi
pass "--owns rejects a file Omarchy did not write"

# A link is somebody else's arrangement even when it resolves to a marked file:
# the launcher is written as a regular file.
marked_elsewhere="$tmpdir/marked-elsewhere"
printf '%s\n' "#!/bin/bash" "$marker" >"$marked_elsewhere"
chmod +x "$marked_elsewhere"
rm -f "$launcher"
ln -s "$marked_elsewhere" "$launcher"
if run --owns; then
  fail "--owns rejects a symbolic link that resolves to a marked file"
fi
pass "--owns rejects a symbolic link that resolves to a marked file"
rm -f "$launcher"

if run --check; then
  fail "--check answers no when no agent resolves"
fi
[[ ! -e $launcher ]] || fail "--check creates no launcher"
pass "--check answers no when no agent resolves"

OMARCHY_TEST_PATH="$agent_bin:$base_path" run --check ||
  fail "--check answers yes for a healthy runtime"
pass "--check answers yes for a healthy runtime"

if OMARCHY_TEST_PATH="$agent_bin:$base_path" OMARCHY_TEST_DOCTOR_JSON="$tmpdir/doctor-bad.json" run --check; then
  fail "--check answers no when a doctor entry is not ok"
fi
pass "--check answers no when a doctor entry is not ok"

# An empty report says nothing was checked, which is not the same as healthy.
if OMARCHY_TEST_PATH="$agent_bin:$base_path" OMARCHY_TEST_DOCTOR_JSON="$tmpdir/doctor-empty.json" run --check; then
  fail "--check answers no for an empty doctor report"
fi
pass "--check answers no for an empty doctor report"

# The launcher precedes the real agent on PATH, the way ~/.local/bin does before
# the mise shims exist. --check has to look past our own launcher, and running it
# would start an install from inside a question.
printf '%s\n' "#!/bin/bash" "$marker" "touch $tmpdir/LAUNCHER-RAN" >"$launcher"
chmod +x "$launcher"
OMARCHY_TEST_PATH="$home/.local/bin:$agent_bin:$base_path" run --check ||
  fail "--check looks past the Omarchy launcher to the installed agent"
[[ ! -e $tmpdir/LAUNCHER-RAN ]] || fail "--check never runs the Omarchy launcher"
pass "--check looks past the Omarchy launcher without running it"
rm -f "$launcher"

# A cold launcher and nothing else is a runtime that is not ready, and asking
# must not start the install the launcher would run.
printf '%s\n' "#!/bin/bash" "$marker" "touch $tmpdir/COLD-LAUNCHER-RAN" >"$launcher"
chmod +x "$launcher"
: >"$curl_log"
if OMARCHY_TEST_PATH="$home/.local/bin:$base_path" run --check; then
  fail "--check answers no when only the cold launcher is present"
fi
[[ ! -e $tmpdir/COLD-LAUNCHER-RAN ]] || fail "--check never runs the cold launcher"
[[ ! -s $curl_log ]] || fail "--check downloads nothing" "$(tr '\0' ' ' <"$curl_log")"
pass "--check answers no when only the cold launcher is present"
rm -f "$launcher"

# The window between the package install and the reshim: the binary is under the
# global npm prefix and nothing on PATH answers for it yet.
mkdir -p "$npm_prefix/bin"
cp "$agent_bin/wasmedge-agent" "$npm_prefix/bin/wasmedge-agent"
run --check || fail "--check finds an agent that only the npm prefix knows about"
pass "--check finds an agent that only the npm prefix knows about"
rm -rf "$npm_prefix"

# npm's global prefix is ~/.local on any machine set up to avoid sudo npm, and
# there $prefix/bin/wasmedge-agent is the launcher. The fallback has to skip it
# for the reason the PATH scan does: answering with the launcher makes the
# launcher exec itself, and a question run out its own timeout. This stands in
# for that by hanging, so the stall is visible without a loop in the suite.
printf '%s\n' "#!/bin/bash" "$marker" "touch $tmpdir/NPM-LAUNCHER-RAN" "sleep 30" >"$launcher"
chmod +x "$launcher"
started=$SECONDS
if OMARCHY_TEST_NPM_PREFIX="$home/.local" run --check; then
  fail "--check answers no when the npm prefix holds nothing but the launcher"
fi
[[ ! -e $tmpdir/NPM-LAUNCHER-RAN ]] ||
  fail "--check never resolves the launcher through the global npm prefix"
(( SECONDS - started < 10 )) ||
  fail "--check answers without waiting out its own timeout" "seconds: $((SECONDS - started))"
pass "--check never resolves the launcher through the global npm prefix"
rm -f "$launcher"

status=0
run --nonsense 2>"$tmpdir/err" || status=$?
(( status == 2 )) || fail "an unknown argument exits 2, not 1" "exit status: $status"
grep -q "Usage: omarchy-install-wasmedge-agent" "$tmpdir/err" ||
  fail "an unknown argument prints usage to stderr" "$(cat "$tmpdir/err")"
pass "an unknown argument prints usage and exits 2"

# --- Task 2: the launcher ---------------------------------------------------

rm -rf "$home"
: >"$curl_log"
run || fail "writing the launcher succeeds on a clean machine"
[[ -f $launcher && -x $launcher ]] || fail "the launcher is an executable regular file"
[[ ! -L $launcher ]] || fail "the launcher is a regular file and not a link"
grep -qxF "$marker" "$launcher" || fail "the launcher carries the ownership marker"
run --owns || fail "the command owns the launcher it just wrote"
pass "a clean machine gets an executable, marked launcher"

# User provisioning calls this on every machine. The agent is minutes of
# download, so writing the launcher must reach the network for nothing.
[[ ! -s $curl_log ]] || fail "writing the launcher downloads nothing" "$(tr '\0' ' ' <"$curl_log")"
pass "writing the launcher downloads nothing"

before=$(cat "$launcher")
run || fail "writing the launcher again succeeds"
[[ $(cat "$launcher") == "$before" ]] || fail "writing the launcher again produces the same file"
pass "writing the launcher is byte-identical on a second run"

chmod -x "$launcher"
run || fail "repairing the launcher succeeds"
[[ -x $launcher ]] || fail "a launcher of ours that lost its executable bit is repaired"
pass "a launcher of ours that lost its executable bit is repaired"

foreign_body='#!/bin/bash
echo mine'
printf '%s\n' "$foreign_body" >"$launcher"
chmod +x "$launcher"
run || fail "a foreign launcher is not an error"
[[ $(cat "$launcher") == "$foreign_body" ]] || fail "a foreign file at the launcher path is left alone"
pass "a foreign file at the launcher path is left alone"

# The marker is matched whole. A wrapper whose own comment quotes it -- including
# one that quotes it to say it is not ours -- is still the user's file, and a
# substring match would silently write over it.
quoting_body="#!/bin/bash
# This is not the \"$marker\" launcher; it is mine.
echo mine"
printf '%s\n' "$quoting_body" >"$launcher"
chmod +x "$launcher"
if run --owns; then
  fail "a file that only quotes the marker inside a longer line is not ours"
fi
run || fail "a file that only quotes the marker is not an error"
[[ $(cat "$launcher") == "$quoting_body" ]] ||
  fail "a file that only quotes the marker is left alone" "$(cat "$launcher")"
pass "a file that quotes the marker inside a longer line is not ours and is left alone"

rm -f "$launcher"
[[ ! -e "$tmpdir/somewhere-else" ]] || fail "the dangling link's target does not exist before the run"
ln -s "$tmpdir/somewhere-else" "$launcher"
run || fail "a foreign symbolic link is not an error"
[[ -L $launcher ]] || fail "a foreign symbolic link at the launcher path is left alone"
[[ $(readlink "$launcher") == "$tmpdir/somewhere-else" ]] || fail "the link still points where it did"
[[ ! -e "$tmpdir/somewhere-else" ]] || fail "nothing was written through the dangling foreign link"
pass "a foreign symbolic link at the launcher path is left alone"
rm -f "$launcher"

# The body goes to a sibling temporary file and is renamed into place, because a
# rename inside a directory is atomic. No run can then leave a half-written file
# at the launcher path: that file carries no marker, so every later run reads it
# as somebody else's, exits 0, and never repairs it, and nothing this command
# offers recovers from that. `cat` writes the body, so a cat that writes part of
# it and then fails is the failure to model.
truncating_bin="$tmpdir/truncating-bin"
mkdir -p "$truncating_bin"
cat >"$truncating_bin/cat" <<'SH'
#!/bin/bash

# The shebang and the beginning of the marker line, then the failure a full disk
# or a signal delivers.
head -c 40
exit 1
SH
chmod +x "$truncating_bin/cat"

rm -rf "$home"
mkdir -p "$home/.local/bin"
status=0
OMARCHY_TEST_PATH="$truncating_bin:$base_path" run >/dev/null 2>&1 || status=$?
(( status != 0 )) || fail "a failed write is reported"
if [[ -e $launcher ]] && ! grep -qxF "$marker" "$launcher"; then
  fail "a failed write leaves no unmarked file at the launcher path" "$(cat "$launcher")"
fi
shopt -s nullglob dotglob
leftover=("$home/.local/bin"/*)
shopt -u nullglob dotglob
(( ${#leftover[@]} == 0 )) ||
  fail "a failed write leaves no temporary file behind" "${leftover[*]}"
pass "a failed write leaves neither an unmarked launcher nor a temporary file"

# A launcher of ours already at the path is the worse half: the redirect that
# used to write it truncated the live file before a byte of the new body
# arrived, so a write that then failed destroyed a launcher that worked.
rm -rf "$home"
run || fail "writing the launcher succeeds"
before=$(cat "$launcher")
status=0
OMARCHY_TEST_PATH="$truncating_bin:$base_path" run >/dev/null 2>&1 || status=$?
(( status != 0 )) || fail "a failed rewrite is reported"
[[ $(cat "$launcher") == "$before" ]] ||
  fail "a failed rewrite leaves the launcher it could not replace intact" "$(cat "$launcher")"
run --owns || fail "a failed rewrite leaves a launcher Omarchy still owns"
shopt -s nullglob dotglob
leftover=("$home/.local/bin"/*)
shopt -u nullglob dotglob
(( ${#leftover[@]} == 1 )) ||
  fail "a failed rewrite leaves no temporary file behind" "${leftover[*]}"
pass "a failed rewrite leaves the launcher it could not replace intact"

# The ownership test runs before the body exists, so a user's own installer can
# create the file in the window between the two. The live path is asked again
# just before the rename, and a file that has appeared there is left alone.
# `cat` writes the body, so a cat that plants a foreign file before writing it
# stands in for that window exactly.
racing_bin="$tmpdir/racing-bin"
mkdir -p "$racing_bin"
cat >"$racing_bin/cat" <<'SH'
#!/bin/bash

printf '%s\n' "#!/bin/bash" "echo mine" >"$HOME/.local/bin/wasmedge-agent"
chmod +x "$HOME/.local/bin/wasmedge-agent"
exec /usr/bin/cat
SH
chmod +x "$racing_bin/cat"

rm -rf "$home"
mkdir -p "$home/.local/bin"
OMARCHY_TEST_PATH="$racing_bin:$base_path" run ||
  fail "a file that appears while the launcher is written is not an error"
[[ $(cat "$launcher") == "$foreign_body" ]] ||
  fail "a user's file that appears while the launcher is written is left alone" \
    "$(cat "$launcher")"
shopt -s nullglob dotglob
leftover=("$home/.local/bin"/*)
shopt -u nullglob dotglob
(( ${#leftover[@]} == 1 )) ||
  fail "the discarded write leaves no temporary file behind" "${leftover[*]}"
pass "a user's file that appears while the launcher is written is left alone"

# The window the test above cannot reach is the one after that last ownership
# test and before the file is published. Asking and then renaming leaves it
# open, because a rename replaces whatever it lands on. These stubs stand in
# that window: each creates a user's command at the launcher path in the instant
# before the real tool runs. Both publication tools are stubbed, so the
# injection happens whichever one the command reaches for, and the user's file
# has to survive either way.
publish_race_bin="$tmpdir/publish-race-bin"
mkdir -p "$publish_race_bin"
racing_body='#!/bin/bash
echo theirs'
for tool in ln mv; do
  cat >"$publish_race_bin/$tool" <<SH
#!/bin/bash

if [[ \$* == *"$launcher"* ]]; then
  printf '%s\\n' '$racing_body' >"$launcher"
  chmod +x "$launcher"
fi

exec $(command -v "$tool") "\$@"
SH
  chmod +x "$publish_race_bin/$tool"
done

rm -rf "$home"
mkdir -p "$home/.local/bin"
OMARCHY_TEST_PATH="$publish_race_bin:$base_path" run ||
  fail "a file that appears just before the launcher is published is not an error"
[[ $(cat "$launcher") == "$racing_body" ]] ||
  fail "a user's file that appears just before publication is not replaced" \
    "$(cat "$launcher")"
if run --owns; then
  fail "the file that appeared just before publication is not claimed as Omarchy's"
fi
shopt -s nullglob dotglob
leftover=("$home/.local/bin"/*)
shopt -u nullglob dotglob
(( ${#leftover[@]} == 1 )) ||
  fail "the abandoned publication leaves no temporary file behind" "${leftover[*]}"
pass "a user's file that appears just before publication is not replaced"

# Publication is not the only window. When the launcher path already holds a
# launcher of ours, the link above it fails and the repair runs instead, and the
# repair has a window of its own: its ownership test stands before the move that
# acts on the path. Only mv is stubbed for this one -- a stub ln would plant the
# file before that ownership test and never reach the window under test.
repair_race_bin="$tmpdir/repair-race-bin"
mkdir -p "$repair_race_bin"
cat >"$repair_race_bin/mv" <<SH
#!/bin/bash

if [[ \$* == *"$launcher"* ]]; then
  printf '%s\\n' '$racing_body' >"$launcher"
  chmod +x "$launcher"
fi

exec $(command -v mv) "\$@"
SH
chmod +x "$repair_race_bin/mv"

rm -rf "$home"
run || fail "writing the launcher succeeds"
OMARCHY_TEST_PATH="$repair_race_bin:$base_path" run ||
  fail "a file that appears just before a repair is not an error"
[[ $(cat "$launcher") == "$racing_body" ]] ||
  fail "a user's file that appears just before a repair is not replaced" \
    "$(cat "$launcher")"
if run --owns; then
  fail "the file that appeared just before a repair is not claimed as Omarchy's"
fi
shopt -s nullglob dotglob
leftover=("$home/.local/bin"/*)
shopt -u nullglob dotglob
(( ${#leftover[@]} == 1 )) ||
  fail "the abandoned repair leaves no temporary file behind" "${leftover[*]}"
pass "a user's file that appears just before a repair is not replaced"

# The warm path: an agent is already installed, so the launcher hands straight
# over to it and reaches no installer. The arguments must arrive as they left,
# including a space and a string that would expand if it were ever evaluated.
rm -rf "$home"
run || fail "writing the launcher succeeds"
mkdir -p "$npm_prefix/bin"
cp "$agent_bin/wasmedge-agent" "$npm_prefix/bin/wasmedge-agent"
: >"$tmpdir/agent.log"
: >"$curl_log"
OMARCHY_TEST_PATH="$home/.local/bin:$base_path" run_launcher chat --model "a b" '$HOME' ||
  fail "the launcher runs the installed agent"
printf '%s\0' chat --model "a b" '$HOME' >"$tmpdir/expected-argv"
cmp -s "$tmpdir/agent.log" "$tmpdir/expected-argv" ||
  fail "the launcher passes its arguments through unchanged" "$(tr '\0' ' ' <"$tmpdir/agent.log")"
[[ ! -s $curl_log ]] || fail "the launcher installs nothing when an agent is already there"
pass "the launcher runs the installed agent with its arguments unchanged"
rm -rf "$npm_prefix"
