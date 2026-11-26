#!/bin/sh
# Controller-side checks that run on macOS or Linux without a macOS build:
# the Recovery shell relay is private to the controller user, and Recovery
# runs only the installer whose digest the printed command carries.
#
# Needs ssh-keygen, uuidgen, curl, python3, a libarchive tar (macOS tar, or
# bsdtar on Linux) and an nc that supports -U (set RECOVERY_SSH_NC otherwise).
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/rs-trust.XXXXXX")
RELAY_RUN_PID=
CONNECT_PID=
HTTP_PID=

cleanup()
{
    for pid in $CONNECT_PID $RELAY_RUN_PID $HTTP_PID; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    rm -f /tmp/recovery-ssh-install
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT HUP INT TERM

fail()
{
    echo "FAIL: $*" >&2
    exit 1
}

NC=${RECOVERY_SSH_NC:-$(command -v nc || true)}
[ -x "$NC" ] || fail "an nc that supports -U is required (set RECOVERY_SSH_NC)"

# A copy of the project with a stand-in PTY helper: it is only bundled here.
PROJECT="$TEMP_ROOT/project"
mkdir -p "$PROJECT/dist"
cp -R "$ROOT/recovery-ssh" "$ROOT/templates" "$ROOT/src" "$PROJECT/"
printf '#!/bin/sh\nexec /bin/sh -i\n' > "$PROJECT/dist/ptywrap"
chmod 755 "$PROJECT/dist/ptywrap"

STATE_BASE="$TEMP_ROOT/s"
printf '127.0.0.1 ssh-ed25519 TEST_HOST_KEY\n' > "$TEMP_ROOT/known_hosts"
touch "$TEMP_ROOT/authorized_keys"

rs()
{
    RECOVERY_SSH_HOME="$STATE_BASE" \
    RECOVERY_SSH_AUTHORIZED_KEYS="$TEMP_ROOT/authorized_keys" \
    RECOVERY_SSH_NC="$NC" \
    RECOVERY_SSH_HTTPD="$PROJECT/src/httpd.py" \
        "$PROJECT/recovery-ssh" "$@"
}

echo "Checking the relay is a private socket, not a TCP port..."
rs setup --name trust --host 127.0.0.1 --user "$(id -un)" \
    --http-port 24601 --host-key-file "$TEMP_ROOT/known_hosts" \
    > "$TEMP_ROOT/setup.out"
STATE="$STATE_BASE/computers/trust"
grep -q "command=\"'$STATE/relay'\"" "$TEMP_ROOT/authorized_keys" ||
    fail "forced command is not the profile's relay script"
grep -q '127.0.0.1' "$STATE/relay" && fail "relay script still uses a TCP port"
grep -q -- "-lU '$STATE/relay.sock'" "$STATE/relay" ||
    fail "relay script does not listen on the profile socket"
mode=$(ls -ld "$STATE" | cut -c1-10)
[ "$mode" = drwx------ ] || fail "profile directory is $mode, not drwx------"

echo "Checking the controller user attaches through the socket..."
mkfifo "$TEMP_ROOT/channel"
# The Recovery side of the forced command: what Recovery's shell sends.
{ printf 'RELAY_SHELL_OK\n'; sleep 5; } > "$TEMP_ROOT/channel" &
RELAY_RUN_PID=$!
sh "$STATE/relay" < "$TEMP_ROOT/channel" > "$TEMP_ROOT/relay.out" &
RELAY_SH_PID=$!
for _ in 1 2 3 4 5; do
    [ -S "$STATE/relay.sock" ] && break
    sleep 1
done
rs status --name trust > "$TEMP_ROOT/status.out"
grep -q 'Recovery shell:    waiting' "$TEMP_ROOT/status.out" ||
    fail "status does not see the waiting relay"
rs list > "$TEMP_ROOT/list.out"
grep -q '^trust .*waiting$' "$TEMP_ROOT/list.out" ||
    fail "list does not see the waiting relay"
rs connect --name trust > "$TEMP_ROOT/connect.out" 2>&1 &
CONNECT_PID=$!
for _ in 1 2 3 4 5 6; do
    grep -q RELAY_SHELL_OK "$TEMP_ROOT/connect.out" && break
    sleep 1
done
grep -q RELAY_SHELL_OK "$TEMP_ROOT/connect.out" ||
    fail "controller did not attach to the relay"
kill "$CONNECT_PID" 2>/dev/null || true
wait "$CONNECT_PID" 2>/dev/null || true
CONNECT_PID=
kill "$RELAY_SH_PID" "$RELAY_RUN_PID" 2>/dev/null || true
wait "$RELAY_SH_PID" 2>/dev/null || true
wait "$RELAY_RUN_PID" 2>/dev/null || true
RELAY_RUN_PID=

if [ "$(id -u)" -eq 0 ] && command -v setpriv >/dev/null 2>&1; then
    echo "Checking another user cannot reach the relay..."
    sh "$STATE/relay" < /dev/null > /dev/null 2>&1 &
    RELAY_RUN_PID=$!
    sleep 1
    if setpriv --reuid=65534 --regid=65534 --clear-groups \
        "$NC" -U "$STATE/relay.sock" < /dev/null > /dev/null 2>&1; then
        fail "another user connected to the relay"
    fi
    kill "$RELAY_RUN_PID" 2>/dev/null || true
    wait "$RELAY_RUN_PID" 2>/dev/null || true
    RELAY_RUN_PID=
else
    echo "Skipping the cross-user check (needs root and setpriv)."
fi

echo "Checking Recovery runs only the installer the command names..."
command_line=$(sed -n "s/^  curl /curl /p" "$TEMP_ROOT/setup.out")
[ -n "$command_line" ] || fail "setup printed no Recovery command"
case "$command_line" in
    *"sha256digest="*) ;;
    *) fail "the Recovery command carries no digest" ;;
esac
TOKEN=$(sed -n "s/^TOKEN='\([^']*\)'$/\1/p" "$STATE/config")

# Recovery's tar is libarchive; on Linux use bsdtar under that name.
SHIM="$TEMP_ROOT/shim"
mkdir -p "$SHIM"
if tar --version 2>/dev/null | grep -q libarchive; then
    :
elif command -v bsdtar >/dev/null 2>&1; then
    ln -s "$(command -v bsdtar)" "$SHIM/tar"
else
    fail "a libarchive tar is required"
fi

serve()
{
    python3 "$PROJECT/src/httpd.py" 127.0.0.1 24601 "/$TOKEN" "$1" \
        > "$TEMP_ROOT/http.log" 2>&1 &
    HTTP_PID=$!
    for _ in 1 2 3 4 5; do
        curl -fsS -o /dev/null "http://127.0.0.1:24601/$TOKEN" 2>/dev/null && return
        sleep 1
    done
    fail "test installer server did not start"
}

stop_serving()
{
    kill "$HTTP_PID" 2>/dev/null || true
    wait "$HTTP_PID" 2>/dev/null || true
    HTTP_PID=
}

recovery_run()
{
    rm -f /tmp/recovery-ssh-install
    PATH="$SHIM:$PATH" RECOVERY_SSH_VOLUME="$1" RECOVERY_SSH_INSTALL_ONLY=1 \
        sh -c "$command_line" > "$TEMP_ROOT/recovery.out" 2>&1
}

# The installer the controller made: verified and run.
mkdir "$TEMP_ROOT/data"
serve "$STATE/install.sh"
recovery_run "$TEMP_ROOT/data" || fail "the genuine installer was not run"
stop_serving
[ -x "$TEMP_ROOT/data/recovery-ssh" ] || fail "the genuine installer did not install"

# A substitute with a consistent embedded size and checksum: not run.
marker="$TEMP_ROOT/substitute-ran"
{
    head -n 1 "$STATE/install.sh"
    printf 'touch "%s"\n' "$marker"
    tail -n +2 "$STATE/install.sh"
} > "$TEMP_ROOT/substitute.sh"
mkdir "$TEMP_ROOT/data2"
RECOVERY_SSH_VOLUME="$TEMP_ROOT/data2" RECOVERY_SSH_INSTALL_ONLY=1 \
    sh "$TEMP_ROOT/substitute.sh" > /dev/null 2>&1 ||
    fail "the substitute is not internally consistent"
rm -f "$marker"
rm -rf "$TEMP_ROOT/data2"
mkdir "$TEMP_ROOT/data2"
serve "$TEMP_ROOT/substitute.sh"
if recovery_run "$TEMP_ROOT/data2"; then
    fail "the Recovery command accepted a substituted installer"
fi
stop_serving
[ ! -e "$marker" ] || fail "the substituted installer ran"
[ ! -e "$TEMP_ROOT/data2/recovery-ssh" ] || fail "the substituted installer installed"

echo "Checking no unauthenticated short bootstrap is served..."
rs serve --name trust > "$TEMP_ROOT/serve.out" 2>&1 &
HTTP_PID=$!
for _ in 1 2 3 4 5 6 7 8; do
    curl -fsS -o /dev/null "http://127.0.0.1:24601/$TOKEN" 2>/dev/null && break
    sleep 1
done
curl -fsS -o /dev/null "http://127.0.0.1:24601/$TOKEN" ||
    fail "serve does not serve the installer"
status=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:24601/r")
[ "$status" = 404 ] || fail "serve answers /r with $status"
stop_serving

echo "All relay and bootstrap trust tests passed."
