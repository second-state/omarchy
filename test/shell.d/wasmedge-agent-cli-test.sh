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
# It reads -f the way curl does, so a test can tell a command that asks for HTTP
# errors to be failures from one that does not.
cat >"$stub_bin/curl" <<'SH'
#!/bin/bash

printf '%s\0' "$@" >>"$OMARCHY_TEST_CURL_LOG"

# -f, alone or in a cluster such as -fsSL, and its long form. Without it curl
# writes a server's error page to the output file and still reports success.
fails_on_http_error=0
output=
while (($#)); do
  case "$1" in
    -o)
      output=$2
      shift 2
      ;;
    --fail)
      fails_on_http_error=1
      shift
      ;;
    --*)
      shift
      ;;
    -*f*)
      fails_on_http_error=1
      shift
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

if [[ ${OMARCHY_TEST_CURL_HTTP_ERROR:-0} == 1 ]]; then
  (( fails_on_http_error )) && exit 22
  cp "$OMARCHY_TEST_CURL_ERROR_BODY" "$output"
  exit 0
fi

cp "$OMARCHY_TEST_INSTALLER" "$output"
SH

# Stands in for the agent's published install.sh: it records how it was called
# and, on success, leaves an agent where npm says a global install lands.
cat >"$tmpdir/fake-installer" <<'SH'
#!/bin/sh

printf 'installer ran: %s\n' "$*" >>"$OMARCHY_TEST_INSTALLER_LOG"
printf 'installer sentinel: %s\n' "${OMARCHY_WASMEDGE_AGENT_INSTALLING:-unset}" >>"$OMARCHY_TEST_INSTALLER_LOG"
printf 'WasmEdge Agent installer: %s\n' "$*"

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

# A signal can end the command between npm publishing its command and this
# installer returning. Sending one to the parent models that exactly: the
# command is waiting on the pipeline this runs in, so it acts on the signal as
# soon as this returns, and neither path that handles an installer's own failure
# ever runs.
if [ "${OMARCHY_TEST_INSTALLER_SIGNALS:-0}" = "1" ]; then
  kill -TERM "$PPID"
  exit 0
fi

# An install can also fail after npm has published the command, while the
# runtime it needs is still incomplete. The launcher does not survive that one,
# so it gets its own switch.
if [ "${OMARCHY_TEST_INSTALLER_PARTIAL:-0}" = "1" ]; then
  printf 'installer failed after npm published the command\n'
  exit 1
fi
SH

# What a 404 or a 502 delivers instead of the installer. It records that it was
# run, because that is the whole cost of losing curl -f: the error body lands in
# the file and sh runs it.
cat >"$tmpdir/curl-error-body" <<'SH'
#!/bin/sh

printf 'error body ran: %s\n' "$*" >>"$OMARCHY_TEST_ERROR_BODY_LOG"
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
    "OMARCHY_TEST_CURL_HTTP_ERROR=${OMARCHY_TEST_CURL_HTTP_ERROR:-0}"
    "OMARCHY_TEST_CURL_ERROR_BODY=$tmpdir/curl-error-body"
    "OMARCHY_TEST_ERROR_BODY_LOG=${OMARCHY_TEST_ERROR_BODY_LOG:-$tmpdir/error-body.log}"
    "OMARCHY_TEST_DOCTOR_JSON=${OMARCHY_TEST_DOCTOR_JSON:-$tmpdir/doctor-ok.json}"
    "OMARCHY_TEST_INSTALLER=$tmpdir/fake-installer"
    "OMARCHY_TEST_INSTALLER_FAILS=${OMARCHY_TEST_INSTALLER_FAILS:-0}"
    "OMARCHY_TEST_INSTALLER_LOG=${OMARCHY_TEST_INSTALLER_LOG:-$tmpdir/installer.log}"
    "OMARCHY_TEST_INSTALLER_PARTIAL=${OMARCHY_TEST_INSTALLER_PARTIAL:-0}"
    "OMARCHY_TEST_INSTALLER_SIGNALS=${OMARCHY_TEST_INSTALLER_SIGNALS:-0}"
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

# The failure a launcher that resolves itself produces is an exec loop, not an
# error, so bound it: a regression has to fail this file rather than hang it.
run_launcher_bounded() {
  build_test_env
  env "${test_env[@]}" timeout 10 "$launcher" "$@"
}

# The launcher as the agent's own published installer reaches it: that installer
# ends by resolving wasmedge-agent and running doctor --fix on the result, and it
# runs inside --now, so the sentinel is set.
run_launcher_installing() {
  build_test_env
  env "${test_env[@]}" OMARCHY_WASMEDGE_AGENT_INSTALLING=1 "$launcher" "$@"
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

# --- Task 3: the install ----------------------------------------------------

rm -rf "$home" "$npm_prefix"
: >"$curl_log"
: >"$tmpdir/installer.log"
run --now >/dev/null || fail "--now installs on a clean machine"
grep -Fq -- "--yes" "$tmpdir/installer.log" ||
  fail "--now runs the installer unattended" "$(cat "$tmpdir/installer.log")"
(( $(grep -c "installer ran" "$tmpdir/installer.log") == 1 )) ||
  fail "--now runs the installer once" "$(cat "$tmpdir/installer.log")"
grep -qz "https://github.com/second-state/wasmedge-agent/releases/latest/download/install.sh" "$curl_log" ||
  fail "--now downloads the published installer by default" "$(tr '\0' ' ' <"$curl_log")"
grep -Fqx "WasmEdge Agent installer: --yes" "$home/.local/state/omarchy/wasmedge-agent-install.log" ||
  fail "--now logs what the installer said" \
    "$(cat "$home/.local/state/omarchy/wasmedge-agent-install.log")"
# The installer ends by resolving wasmedge-agent and running doctor --fix on it,
# which on a fresh machine is the launcher. The sentinel is what stops that
# launcher asking for a second install from inside this one.
grep -Fqx "installer sentinel: 1" "$tmpdir/installer.log" ||
  fail "--now marks the install the installer runs inside" "$(cat "$tmpdir/installer.log")"
run --owns || fail "--now leaves a launcher Omarchy owns"
pass "--now downloads the published installer, runs it unattended, and logs it"

# The override is what these tests and a clean-guest validation use, because the
# release repository is private and GitHub answers 404 for its assets.
rm -rf "$home" "$npm_prefix"
: >"$curl_log"
OMARCHY_WASMEDGE_AGENT_INSTALLER_URL="http://localhost:8000/install.sh" run --now >/dev/null ||
  fail "--now installs from an overridden URL"
grep -qz "http://localhost:8000/install.sh" "$curl_log" ||
  fail "--now downloads the URL it was given" "$(tr '\0' ' ' <"$curl_log")"
pass "--now honours OMARCHY_WASMEDGE_AGENT_INSTALLER_URL"

# A failed install leaves a launcher that can try again, rather than a machine
# with no wasmedge-agent at all.
rm -rf "$home" "$npm_prefix"
status=0
OMARCHY_TEST_INSTALLER_FAILS=1 run --now >/dev/null 2>"$tmpdir/err" || status=$?
(( status == 1 )) || fail "a failed install exits 1" "exit status: $status"
[[ -f $launcher ]] || fail "a failed install leaves the launcher in place"
grep -q "wasmedge-agent-install.log" "$tmpdir/err" ||
  fail "a failed install says where the log is" "$(cat "$tmpdir/err")"
grep -q -- "--now again to retry" "$tmpdir/err" ||
  fail "a failed install says how to retry" "$(cat "$tmpdir/err")"
pass "a failed install is diagnosable and retryable"

rm -rf "$home" "$npm_prefix"
status=0
OMARCHY_TEST_CURL_FAILS=1 run --now >/dev/null 2>"$tmpdir/err" || status=$?
(( status == 1 )) || fail "a failed download exits 1" "exit status: $status"
[[ -f $launcher ]] || fail "a failed download leaves the launcher in place"
grep -q "Could not download" "$tmpdir/err" ||
  fail "a failed download says so" "$(cat "$tmpdir/err")"
pass "a failed download is diagnosable and retryable"

# An HTTP error is a failed download too. Without curl -f the error page is
# written to the file and run as if it were the installer, so the body records
# that it ran and this asserts it never did.
rm -rf "$home" "$npm_prefix"
: >"$tmpdir/error-body.log"
: >"$tmpdir/installer.log"
status=0
OMARCHY_TEST_CURL_HTTP_ERROR=1 run --now >/dev/null 2>"$tmpdir/err" || status=$?
(( status == 1 )) || fail "an HTTP error exits 1" "exit status: $status"
grep -q "Could not download" "$tmpdir/err" ||
  fail "an HTTP error is reported as a failed download" "$(cat "$tmpdir/err")"
[[ ! -s $tmpdir/error-body.log ]] ||
  fail "an HTTP error's body is never run" "$(cat "$tmpdir/error-body.log")"
[[ ! -s $tmpdir/installer.log ]] ||
  fail "an HTTP error runs no installer" "$(cat "$tmpdir/installer.log")"
pass "an HTTP error body is never run as the installer"

# Somebody else's binary at the launcher path: nothing is installed over it. A
# working one is what the default agent will run, and a broken one is theirs.
rm -rf "$home" "$npm_prefix"
mkdir -p "$home/.local/bin"
printf '%s\n' "#!/bin/bash" "echo mine" >"$launcher"
chmod +x "$launcher"
cp "$launcher" "$tmpdir/foreign-unready-launcher-before"
: >"$curl_log"
status=0
run --now >/dev/null 2>"$tmpdir/err" || status=$?
(( status == 1 )) || fail "--now reports a foreign launcher with an unready runtime" "exit status: $status"
[[ ! -s $curl_log ]] || fail "--now downloads nothing when the launcher path is foreign"
grep -q "was not installed by Omarchy" "$tmpdir/err" ||
  fail "--now names the foreign launcher" "$(cat "$tmpdir/err")"
cmp -s "$launcher" "$tmpdir/foreign-unready-launcher-before" ||
  fail "--now leaves the foreign launcher's own content untouched"
pass "--now installs nothing over a launcher Omarchy did not write"

rm -rf "$home" "$npm_prefix"
mkdir -p "$home/.local/bin" "$npm_prefix/bin"
cp "$agent_bin/wasmedge-agent" "$launcher"
cp "$agent_bin/wasmedge-agent" "$npm_prefix/bin/wasmedge-agent"
cp "$launcher" "$tmpdir/foreign-working-agent-before"
: >"$curl_log"
OMARCHY_TEST_PATH="$home/.local/bin:$base_path" run --now >/dev/null ||
  fail "--now accepts a working agent the user installed"
[[ ! -s $curl_log ]] || fail "--now downloads nothing over a working user install"
cmp -s "$launcher" "$tmpdir/foreign-working-agent-before" ||
  fail "--now leaves the user's working agent untouched"
pass "--now accepts a working agent the user installed"

# The cold launcher: first run installs the runtime and then runs the agent.
rm -rf "$home" "$npm_prefix"
run || fail "writing the launcher succeeds"
: >"$tmpdir/installer.log"
: >"$tmpdir/agent.log"
# The argument is one --now's own readiness probe never passes, so the agent log
# can only hold it if the launcher itself reached the exec.
OMARCHY_TEST_PATH="$home/.local/bin:$ROOT/bin:$base_path" run_launcher chat --cold-probe >/dev/null ||
  fail "the cold launcher installs and then runs the agent"
grep -Fq -- "--yes" "$tmpdir/installer.log" ||
  fail "the cold launcher runs the installer unattended" "$(cat "$tmpdir/installer.log")"
grep -qz -- "--cold-probe" "$tmpdir/agent.log" ||
  fail "the cold launcher runs the agent afterwards" "$(tr '\0' ' ' <"$tmpdir/agent.log")"
pass "the cold launcher installs the runtime and then runs the agent"

# A command that claims success and installs nothing must not make the launcher
# run an empty command name.
rm -rf "$home" "$npm_prefix"
run || fail "writing the launcher succeeds"
lying_cmd_bin="$tmpdir/lying-cmd"
mkdir -p "$lying_cmd_bin"
printf '%s\n' "#!/bin/bash" "exit 0" >"$lying_cmd_bin/omarchy-install-wasmedge-agent"
chmod +x "$lying_cmd_bin/omarchy-install-wasmedge-agent"
status=0
OMARCHY_TEST_PATH="$home/.local/bin:$lying_cmd_bin:$base_path" \
  run_launcher --version >/dev/null 2>"$tmpdir/err" || status=$?
(( status == 1 )) || fail "the launcher exits 1 when an install resolves no agent" "exit status: $status"
grep -q "no wasmedge-agent was found" "$tmpdir/err" ||
  fail "the launcher says what it looked for" "$(cat "$tmpdir/err")"
pass "the launcher refuses to run an agent it cannot find after a successful install"

# The agent's published installer ends by resolving wasmedge-agent and running
# doctor --fix on it. On a fresh machine ~/.local/bin is on PATH and no shim
# exists yet, so that is this launcher, and a launcher that called --now from in
# there would start an install on top of the install running it.
rm -rf "$home" "$npm_prefix"
run || fail "writing the launcher succeeds"
spy_cmd_bin="$tmpdir/spy-cmd"
mkdir -p "$spy_cmd_bin"
printf '%s\n' "#!/bin/bash" "touch $tmpdir/COMMAND-CALLED-FROM-INSTALL" \
  >"$spy_cmd_bin/omarchy-install-wasmedge-agent"
chmod +x "$spy_cmd_bin/omarchy-install-wasmedge-agent"
status=0
OMARCHY_TEST_PATH="$home/.local/bin:$spy_cmd_bin:$base_path" \
  run_launcher_installing chat >/dev/null 2>"$tmpdir/err" || status=$?
(( status == 1 )) || fail "the launcher exits 1 from inside its own install" "exit status: $status"
[[ ! -e $tmpdir/COMMAND-CALLED-FROM-INSTALL ]] ||
  fail "the launcher calls no installer from inside its own install"
grep -q "from inside its own install" "$tmpdir/err" ||
  fail "the launcher names the situation" "$(cat "$tmpdir/err")"
pass "the launcher starts no second install from inside the first"

# The guard is only for the branch that would install. An agent that resolves is
# run whatever is in progress, which is how the installer's own doctor --fix
# reaches the agent it has just installed.
: >"$tmpdir/agent.log"
OMARCHY_TEST_PATH="$home/.local/bin:$agent_bin:$spy_cmd_bin:$base_path" \
  run_launcher_installing doctor --fix >/dev/null ||
  fail "the launcher runs a resolved agent from inside the install"
grep -qz -- "--fix" "$tmpdir/agent.log" ||
  fail "the launcher runs a resolved agent from inside the install" \
    "$(tr '\0' ' ' <"$tmpdir/agent.log")"
[[ ! -e $tmpdir/COMMAND-CALLED-FROM-INSTALL ]] ||
  fail "the launcher installs nothing when an agent resolves"
pass "the launcher still runs a resolved agent from inside the install"

# The launcher carries the same fallback, and on a machine whose global npm
# prefix is ~/.local the candidate it names is the launcher itself. A launcher
# that answered with it would exec itself for as long as anyone let it.
rm -rf "$home" "$npm_prefix"
run || fail "writing the launcher succeeds"
rm -f "$tmpdir/COMMAND-CALLED-FROM-INSTALL"
status=0
OMARCHY_TEST_NPM_PREFIX="$home/.local" OMARCHY_TEST_PATH="$spy_cmd_bin:$base_path" \
  run_launcher_bounded chat >/dev/null 2>"$tmpdir/err" || status=$?
(( status == 1 )) ||
  fail "the launcher never resolves itself through the global npm prefix" "exit status: $status"
[[ -e $tmpdir/COMMAND-CALLED-FROM-INSTALL ]] ||
  fail "the launcher treats itself as nothing found and asks for an install"
grep -q "no wasmedge-agent was found" "$tmpdir/err" ||
  fail "the launcher says what it looked for" "$(cat "$tmpdir/err")"
pass "the launcher never resolves itself through the global npm prefix"

# --- Task 4: npm's global prefix is the launcher's own directory -------------

# `npm config set prefix ~/.local` is the ordinary way to avoid sudo npm, and
# there the path npm creates its command at is the launcher's own. npm refuses
# to create its command over a file it did not create, so the launcher has to
# step aside for the install, and come back only if the install leaves that path
# free.
agent_install_log="$home/.local/state/omarchy/wasmedge-agent-install.log"
launcher_aside="$home/.local/bin/.wasmedge-agent.omarchy-aside"
install_pending="$home/.local/state/omarchy/wasmedge-agent-install.pending"

rm -rf "$home" "$npm_prefix"
: >"$tmpdir/installer.log"
OMARCHY_TEST_NPM_PREFIX="$home/.local" run --now >/dev/null ||
  fail "--now installs when npm's global prefix is the launcher's own directory" \
    "$(cat "$agent_install_log" 2>/dev/null)"
if grep -Fq "EEXIST" "$agent_install_log"; then
  fail "--now got the install past npm's refusal" "$(cat "$agent_install_log")"
fi
OMARCHY_TEST_NPM_PREFIX="$home/.local" run --check ||
  fail "the runtime resolves after an install into the launcher's own directory"
cmp -s "$launcher" "$agent_bin/wasmedge-agent" ||
  fail "the agent the install produced holds the launcher path" "$(cat "$launcher")"
shopt -s nullglob dotglob
leftover=("$home/.local/bin"/*)
shopt -u nullglob dotglob
(( ${#leftover[@]} == 1 )) ||
  fail "the install leaves nothing beside the agent in that directory" "${leftover[*]}"
[[ ! -e $install_pending ]] ||
  fail "a finished install leaves no record of one being under way" \
    "$(ls -a "$home/.local/state/omarchy")"
pass "--now installs where npm's global prefix is the launcher's own directory"

# The launcher that stepped aside has to come back when the install does not
# produce a runtime, or --now has spent the one thing that could try again.
rm -rf "$home" "$npm_prefix"
status=0
OMARCHY_TEST_NPM_PREFIX="$home/.local" OMARCHY_TEST_INSTALLER_FAILS=1 \
  run --now >/dev/null 2>"$tmpdir/err" || status=$?
(( status == 1 )) ||
  fail "a failed install into the launcher's own directory exits 1" "exit status: $status"
run --owns ||
  fail "a failed install puts the launcher back" "$(ls -a "$home/.local/bin")"
[[ ! -e $launcher_aside ]] || fail "the moved-aside launcher is not left behind"
grep -q -- "--now again to retry" "$tmpdir/err" ||
  fail "a failed install says how to retry" "$(cat "$tmpdir/err")"
: >"$tmpdir/installer.log"
OMARCHY_TEST_NPM_PREFIX="$home/.local" run --now >/dev/null ||
  fail "the retry installs after a failure that moved the launcher aside" \
    "$(cat "$agent_install_log")"
OMARCHY_TEST_NPM_PREFIX="$home/.local" run --check ||
  fail "the retry leaves a runtime that resolves"
pass "a failed install into the launcher's own directory restores the launcher, and a retry works"

# A user's own command can reach the aside path by the same window: the
# ownership test stands before the move, and the move relocates whatever the
# path holds by the time it runs. Displaced is recoverable and deleted is not,
# so the copy at that path is only ever dropped when this command wrote it.
rm -rf "$home" "$npm_prefix"
mkdir -p "$home/.local/bin"
printf '%s\n' "#!/bin/bash" "echo theirs" >"$launcher_aside"
chmod +x "$launcher_aside"
: >"$tmpdir/installer.log"
run --now >/dev/null 2>"$tmpdir/err" ||
  fail "--now installs with a file left at the aside path" "$(cat "$tmpdir/err")"
[[ -f $launcher_aside ]] ||
  fail "a file at the aside path that Omarchy did not write is never deleted" \
    "$(ls -a "$home/.local/bin")"
grep -qxF "echo theirs" "$launcher_aside" ||
  fail "that file is left exactly as it was" "$(cat "$launcher_aside")"
pass "a file at the aside path that Omarchy did not write is never deleted"

# The move onto the aside path is a rename, and a rename replaces what it finds.
# Reaching it needs npm's prefix to be the launcher's own directory, which the
# test above does not arrange, so it asks the other half of the question: a file
# at that path that this command did not write is not moved over either. It is
# the very file the restore above went out of its way to keep.
rm -rf "$home" "$npm_prefix"
mkdir -p "$home/.local/bin"
printf '%s\n' "#!/bin/bash" "echo theirs" >"$launcher_aside"
chmod +x "$launcher_aside"
: >"$tmpdir/installer.log"
: >"$curl_log"
status=0
OMARCHY_TEST_NPM_PREFIX="$home/.local" run --now >/dev/null 2>"$tmpdir/err" || status=$?
(( status == 1 )) ||
  fail "--now refuses when the aside path holds a file it did not write" \
    "exit status: $status"
grep -qxF "echo theirs" "$launcher_aside" ||
  fail "the move aside never replaces that file" "$(cat "$launcher_aside")"
[[ ! -s $curl_log ]] ||
  fail "--now downloads nothing when it cannot move the launcher aside" \
    "$(tr '\0' ' ' <"$curl_log")"
grep -qF "$launcher_aside" "$tmpdir/err" ||
  fail "--now names the file that stopped it" "$(cat "$tmpdir/err")"
run --owns ||
  fail "the launcher it wrote before refusing is still there" "$(ls -a "$home/.local/bin")"
pass "--now never moves the launcher over a file at the aside path it did not write"

# `npm prefix -g` can answer a path that reaches the same directory through a
# symbolic link, and a string compare would call that no collision and walk
# straight back into npm's refusal.
rm -rf "$home" "$npm_prefix"
run || fail "writing the launcher succeeds"
ln -sfn "$home/.local" "$tmpdir/linked-prefix"
: >"$tmpdir/installer.log"
OMARCHY_TEST_NPM_PREFIX="$tmpdir/linked-prefix" run --now >/dev/null ||
  fail "--now installs when npm names the launcher's directory through a link" \
    "$(cat "$agent_install_log" 2>/dev/null)"
OMARCHY_TEST_NPM_PREFIX="$tmpdir/linked-prefix" run --check ||
  fail "the runtime resolves after an install npm named through a link"
[[ ! -e $launcher_aside ]] || fail "no moved-aside launcher is left behind"
pass "--now canonicalises npm's prefix, so a link to the launcher's directory still collides"

# End to end on such a machine. The launcher is the process that calls --now, so
# this is also where --now renames a script that is running: the rename keeps the
# inode and the shell keeps its open descriptor, so the launcher goes on to its
# own exec afterwards.
rm -rf "$home" "$npm_prefix"
run || fail "writing the launcher succeeds"
: >"$tmpdir/installer.log"
: >"$tmpdir/agent.log"
OMARCHY_TEST_NPM_PREFIX="$home/.local" \
  OMARCHY_TEST_PATH="$home/.local/bin:$ROOT/bin:$base_path" \
  run_launcher_bounded chat --cold-probe >/dev/null ||
  fail "the cold launcher installs where npm's prefix is its own directory" \
    "$(cat "$agent_install_log" 2>/dev/null)"
grep -Fq -- "--yes" "$tmpdir/installer.log" ||
  fail "the cold launcher runs the installer unattended" "$(cat "$tmpdir/installer.log")"
grep -qz -- "--cold-probe" "$tmpdir/agent.log" ||
  fail "the cold launcher runs the agent afterwards" "$(tr '\0' ' ' <"$tmpdir/agent.log")"
[[ ! -e $launcher_aside ]] || fail "the cold launcher leaves no moved-aside copy behind"
pass "the cold launcher installs and runs the agent where npm's prefix is its own directory"

# An install can also fail after npm has published the agent's command, which in
# this prefix is at the launcher's own path. The launcher does not come back
# from that: the copy moved aside is dropped, because the path it would return
# to is occupied. This command is then the only thing left that can repair the
# machine, so npm's command must not read to it as a file the user put there.
rm -rf "$home" "$npm_prefix"
status=0
OMARCHY_TEST_NPM_PREFIX="$home/.local" OMARCHY_TEST_INSTALLER_PARTIAL=1 \
  run --now >/dev/null 2>"$tmpdir/err" || status=$?
(( status == 1 )) ||
  fail "an install that fails after npm published the command exits 1" "exit status: $status"
[[ -L $launcher ]] ||
  fail "that failure leaves npm's own command at the launcher path" \
    "$(ls -la "$home/.local/bin")"
if run --owns; then
  fail "the launcher does not survive an install that failed after npm published"
fi
: >"$tmpdir/installer.log"
OMARCHY_TEST_NPM_PREFIX="$home/.local" run --now >/dev/null ||
  fail "the retry after that failure installs" "$(cat "$agent_install_log" 2>/dev/null)"
grep -Fq -- "--yes" "$tmpdir/installer.log" ||
  fail "the retry runs the installer again" "$(cat "$tmpdir/installer.log")"
OMARCHY_TEST_NPM_PREFIX="$home/.local" run --check ||
  fail "the retry leaves a runtime that resolves"
pass "an install that fails after npm published the command is still retryable"

# That retry rests on this command having started the install that was cut
# short. A user's own `npm install -g wasmedge-agent` leaves the same link at
# the same path, and section 6 makes it foreign like anything else this command
# did not write: without a record of an install of ours left unfinished, the
# link is somebody's own and --now installs nothing over it.
rm -rf "$home" "$npm_prefix"
mkdir -p "$home/.local/bin" "$home/.local/lib/node_modules/wasmedge-agent"
printf '%s\n' "#!/bin/sh" "exit 0" >"$home/.local/lib/node_modules/wasmedge-agent/cli.js"
chmod +x "$home/.local/lib/node_modules/wasmedge-agent/cli.js"
ln -s "../lib/node_modules/wasmedge-agent/cli.js" "$launcher"
: >"$tmpdir/installer.log"
: >"$curl_log"
status=0
OMARCHY_TEST_NPM_PREFIX="$home/.local" run --now >/dev/null 2>"$tmpdir/err" || status=$?
(( status == 1 )) ||
  fail "--now refuses an npm install this command did not start" "exit status: $status"
[[ ! -s $curl_log ]] ||
  fail "--now downloads nothing over an npm install it did not start" \
    "$(tr '\0' ' ' <"$curl_log")"
[[ ! -s $tmpdir/installer.log ]] ||
  fail "--now runs no installer over an npm install it did not start" \
    "$(cat "$tmpdir/installer.log")"
[[ $(readlink "$launcher") == "../lib/node_modules/wasmedge-agent/cli.js" ]] ||
  fail "that command is left exactly as it was" "$(readlink "$launcher")"
grep -q "not installed by Omarchy" "$tmpdir/err" ||
  fail "--now says whose file it refused" "$(cat "$tmpdir/err")"
pass "--now refuses npm's own command when no install of this command's was left unfinished"

# An install that never got as far as downloading published no command, so it
# leaves nothing for a retry to reclaim. Recording that an attempt merely
# started would hand the next run a claim over whatever turns up at that path --
# including the agent the user goes on to install themselves.
rm -rf "$home" "$npm_prefix"
status=0
OMARCHY_TEST_NPM_PREFIX="$home/.local" OMARCHY_TEST_CURL_FAILS=1 \
  run --now >/dev/null 2>&1 || status=$?
(( status == 1 )) || fail "an install whose download fails exits 1" "exit status: $status"

rm -f "$launcher"
mkdir -p "$home/.local/lib/node_modules/wasmedge-agent"
printf '%s\n' "#!/bin/sh" "exit 0" >"$home/.local/lib/node_modules/wasmedge-agent/cli.js"
chmod +x "$home/.local/lib/node_modules/wasmedge-agent/cli.js"
ln -s "../lib/node_modules/wasmedge-agent/cli.js" "$launcher"
: >"$tmpdir/installer.log"
: >"$curl_log"
status=0
OMARCHY_TEST_NPM_PREFIX="$home/.local" run --now >/dev/null 2>"$tmpdir/err" || status=$?
(( status == 1 )) ||
  fail "--now refuses an npm install the user made after a download of ours failed" \
    "exit status: $status"
[[ ! -s $curl_log ]] ||
  fail "--now downloads nothing over that install" "$(tr '\0' ' ' <"$curl_log")"
[[ $(readlink "$launcher") == "../lib/node_modules/wasmedge-agent/cli.js" ]] ||
  fail "that install is left exactly as it was" "$(readlink "$launcher")"
grep -q "not installed by Omarchy" "$tmpdir/err" ||
  fail "--now says whose file it refused" "$(cat "$tmpdir/err")"
pass "a download that failed leaves no claim over an npm install the user makes later"

# What the retry reclaims is the command this install published, and not any
# command that later holds the path. npm creating a fresh one for the same
# package is exactly what a user's own reinstall does, and the link it leaves
# looks identical -- so the record names the one that was left behind.
rm -rf "$home" "$npm_prefix"
status=0
OMARCHY_TEST_NPM_PREFIX="$home/.local" OMARCHY_TEST_INSTALLER_PARTIAL=1 \
  run --now >/dev/null 2>&1 || status=$?
(( status == 1 )) ||
  fail "an install that fails after npm published exits 1" "exit status: $status"
[[ -L $launcher ]] ||
  fail "npm's command holds the launcher path" "$(ls -la "$home/.local/bin")"

published=$(readlink "$launcher")
rm -f "$launcher"
ln -s "$published" "$launcher"
: >"$tmpdir/installer.log"
: >"$curl_log"
status=0
OMARCHY_TEST_NPM_PREFIX="$home/.local" OMARCHY_TEST_DOCTOR_JSON="$tmpdir/doctor-bad.json" \
  run --now >/dev/null 2>"$tmpdir/err" || status=$?
(( status == 1 )) ||
  fail "--now refuses a command that replaced the one it published" "exit status: $status"
[[ ! -s $curl_log ]] ||
  fail "--now downloads nothing over a command it did not publish" \
    "$(tr '\0' ' ' <"$curl_log")"
[[ ! -s $tmpdir/installer.log ]] ||
  fail "--now runs no installer over a command it did not publish" \
    "$(cat "$tmpdir/installer.log")"
[[ $(readlink "$launcher") == "$published" ]] ||
  fail "that command is left exactly as it was" "$(readlink "$launcher")"
grep -q "not installed by Omarchy" "$tmpdir/err" ||
  fail "--now treats it as a file it did not write" "$(cat "$tmpdir/err")"
pass "the retry reclaims only the command the interrupted install published"

# A signal can end the command after npm published its command and before the
# installer returns, and then neither path that handles a failing install runs.
# What is left is npm's command at the launcher path, no launcher, and -- unless
# the exit itself records it -- no claim over it. Nothing could ever retry: the
# command would read its own half-finished install as somebody else's.
rm -rf "$home" "$npm_prefix"
: >"$tmpdir/installer.log"
status=0
OMARCHY_TEST_NPM_PREFIX="$home/.local" OMARCHY_TEST_INSTALLER_SIGNALS=1 \
  run --now >/dev/null 2>&1 || status=$?
(( status == 143 )) ||
  fail "the command is ended by the signal, not by a path that handles a failure" \
    "exit status: $status"
[[ -L $launcher ]] ||
  fail "npm's command still holds the launcher path after the signal" \
    "$(ls -la "$home/.local/bin")"
if run --owns; then
  fail "no launcher of ours survives a signal that lands after npm published"
fi
[[ -f $install_pending ]] ||
  fail "an exit a signal causes still records what npm published" \
    "$(ls -a "$home/.local/state/omarchy" 2>/dev/null)"
: >"$tmpdir/installer.log"
OMARCHY_TEST_NPM_PREFIX="$home/.local" run --now >/dev/null 2>"$tmpdir/err" ||
  fail "the retry after a signal installs" "$(cat "$tmpdir/err")"
grep -Fq -- "--yes" "$tmpdir/installer.log" ||
  fail "the retry after a signal runs the installer again" "$(cat "$tmpdir/installer.log")"
OMARCHY_TEST_NPM_PREFIX="$home/.local" run --check ||
  fail "the retry after a signal leaves a runtime that resolves"
pass "an install a signal ends after npm published is still retryable"

# The record has to name the same command in every timezone. A rendered local
# time does not: the same link reads differently after the zone changes, and a
# retry that is owed would be refused on a machine that merely travelled.
rm -rf "$home" "$npm_prefix"
status=0
TZ=UTC OMARCHY_TEST_NPM_PREFIX="$home/.local" OMARCHY_TEST_INSTALLER_PARTIAL=1 \
  run --now >/dev/null 2>&1 || status=$?
(( status == 1 )) ||
  fail "an install that fails after npm published exits 1 under TZ=UTC" \
    "exit status: $status"
: >"$tmpdir/installer.log"
TZ=Asia/Tokyo OMARCHY_TEST_NPM_PREFIX="$home/.local" \
  run --now >/dev/null 2>"$tmpdir/err" ||
  fail "the retry works from a different timezone" "$(cat "$tmpdir/err")"
grep -Fq -- "--yes" "$tmpdir/installer.log" ||
  fail "the retry from a different timezone runs the installer" \
    "$(cat "$tmpdir/installer.log")"
pass "the record of an interrupted install does not depend on the timezone"

# npm's command is recognised by resolving into npm's own module tree, and
# nothing else is. A user's link resolves somewhere else and stays theirs,
# however the global prefix is arranged.
rm -rf "$home" "$npm_prefix"
mkdir -p "$home/.local/bin"
ln -s "$agent_bin/wasmedge-agent" "$launcher"
: >"$tmpdir/installer.log"
status=0
OMARCHY_TEST_NPM_PREFIX="$home/.local" OMARCHY_TEST_DOCTOR_JSON="$tmpdir/doctor-bad.json" \
  run --now >/dev/null 2>"$tmpdir/err" || status=$?
(( status == 1 )) ||
  fail "--now refuses a user's own link at the launcher path" "exit status: $status"
[[ ! -s $tmpdir/installer.log ]] ||
  fail "--now runs no installer over a user's own link" "$(cat "$tmpdir/installer.log")"
[[ $(readlink "$launcher") == "$agent_bin/wasmedge-agent" ]] ||
  fail "the user's own link is left exactly as it was" "$(readlink "$launcher")"
grep -q "not installed by Omarchy" "$tmpdir/err" ||
  fail "--now says whose file it refused" "$(cat "$tmpdir/err")"
pass "--now still refuses a user's own link where npm's prefix is the launcher's directory"

# npm's command for the agent is a link into the agent's own package directory.
# A link into some other package's directory is npm's work for that package, and
# no more this command's than a hand-rolled wrapper is. Reading the whole module
# tree as ours starts an install that npm ends with EEXIST -- after the upstream
# installer has already provisioned a toolchain.
rm -rf "$home" "$npm_prefix"
mkdir -p "$home/.local/bin" "$home/.local/lib/node_modules/custom"
printf '%s\n' "#!/bin/sh" "exit 0" >"$home/.local/lib/node_modules/custom/cli.js"
chmod +x "$home/.local/lib/node_modules/custom/cli.js"
ln -s "../lib/node_modules/custom/cli.js" "$launcher"
: >"$tmpdir/installer.log"
: >"$curl_log"
status=0
OMARCHY_TEST_NPM_PREFIX="$home/.local" run --now >/dev/null 2>"$tmpdir/err" || status=$?
(( status == 1 )) ||
  fail "--now refuses a link into another npm package's directory" "exit status: $status"
[[ ! -s $curl_log ]] ||
  fail "--now downloads nothing over another package's command" "$(tr '\0' ' ' <"$curl_log")"
[[ ! -s $tmpdir/installer.log ]] ||
  fail "--now runs no installer over another package's command" \
    "$(cat "$tmpdir/installer.log")"
[[ $(readlink "$launcher") == "../lib/node_modules/custom/cli.js" ]] ||
  fail "another package's command is left exactly as it was" "$(readlink "$launcher")"
grep -q "not installed by Omarchy" "$tmpdir/err" ||
  fail "--now says whose file it refused" "$(cat "$tmpdir/err")"
pass "--now refuses a link into another npm package's directory"

# The link has to resolve, not merely point the right way. A dangling link into
# npm's module tree runs nothing, and treating it as an installed agent would be
# a lie -- one that a resolution allowing missing components would tell.
rm -rf "$home" "$npm_prefix"
mkdir -p "$home/.local/bin"
ln -s "$home/.local/lib/node_modules/wasmedge-agent/cli.js" "$launcher"
[[ ! -e $launcher ]] || fail "the link dangles before the run"
: >"$tmpdir/installer.log"
status=0
OMARCHY_TEST_NPM_PREFIX="$home/.local" run --now >/dev/null 2>"$tmpdir/err" || status=$?
(( status == 1 )) ||
  fail "--now refuses a dangling link into npm's module tree" "exit status: $status"
[[ ! -s $tmpdir/installer.log ]] ||
  fail "--now runs no installer over a dangling link" "$(cat "$tmpdir/installer.log")"
[[ -L $launcher ]] || fail "the dangling link is left where it was"
pass "--now refuses a dangling link into npm's module tree"
