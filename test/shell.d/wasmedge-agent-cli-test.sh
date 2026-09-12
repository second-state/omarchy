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
