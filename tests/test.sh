#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/recovery-ssh-test.XXXXXX")
HTTP_PID=
LISTENER_PID=
CONNECT_PID=
PTY_EOF_PID=
LAUNCHER_PID=

cleanup()
{
    if [ -n "$HTTP_PID" ]; then
        kill "$HTTP_PID" 2>/dev/null || true
        wait "$HTTP_PID" 2>/dev/null || true
    fi
    if [ -n "$LISTENER_PID" ]; then
        kill "$LISTENER_PID" 2>/dev/null || true
        wait "$LISTENER_PID" 2>/dev/null || true
    fi
    if [ -n "$CONNECT_PID" ]; then
        kill "$CONNECT_PID" 2>/dev/null || true
        wait "$CONNECT_PID" 2>/dev/null || true
    fi
    if [ -n "$PTY_EOF_PID" ]; then
        kill "$PTY_EOF_PID" 2>/dev/null || true
        wait "$PTY_EOF_PID" 2>/dev/null || true
    fi
    if [ -n "$LAUNCHER_PID" ]; then
        kill "$LAUNCHER_PID" 2>/dev/null || true
        wait "$LAUNCHER_PID" 2>/dev/null || true
    fi
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT HUP INT TERM

echo "Checking POSIX shell syntax..."
sh -n "$ROOT/recovery-ssh"
sh -n "$ROOT/templates/launcher.sh.in"
sh -n "$ROOT/templates/install.sh.in"

echo "Checking universal helper binaries..."
archs=$(lipo -archs "$ROOT/dist/ptywrap")
case " $archs " in
    *" arm64 "*) ;;
    *) echo "ptywrap is missing arm64: $archs" >&2; exit 1 ;;
esac
case " $archs " in
    *" x86_64 "*) ;;
    *) echo "ptywrap is missing x86_64: $archs" >&2; exit 1 ;;
esac
archs=$(lipo -archs "$ROOT/dist/httpd")
case " $archs " in
    *" arm64 "*) ;;
    *) echo "httpd is missing arm64: $archs" >&2; exit 1 ;;
esac
case " $archs " in
    *" x86_64 "*) ;;
    *) echo "httpd is missing x86_64: $archs" >&2; exit 1 ;;
esac

echo "Checking Recovery PTY relay..."
printf 'echo RECOVERY_PTY_OK; exit\n' | "$ROOT/dist/ptywrap" \
    > "$TEMP_ROOT/pty.out" 2>&1
grep -q RECOVERY_PTY_OK "$TEMP_ROOT/pty.out"

echo "Checking PTY relay exits when its transport closes..."
: | "$ROOT/dist/ptywrap" > "$TEMP_ROOT/pty-eof.out" 2>&1 &
PTY_EOF_PID=$!
for _wait in 1 2 3 4 5; do
    kill -0 "$PTY_EOF_PID" 2>/dev/null || break
    sleep 1
done
if kill -0 "$PTY_EOF_PID" 2>/dev/null; then
    echo "PTY relay stayed alive after transport EOF" >&2
    exit 1
fi
wait "$PTY_EOF_PID" 2>/dev/null || true
PTY_EOF_PID=

echo "Checking tokenized HTTP server..."
printf '#!/bin/sh\nprintf "RECOVERY_HTTP_OK\\n"\n' > "$TEMP_ROOT/http-source"
HTTP_PORT=$((30000 + $$ % 20000))
"$ROOT/dist/httpd" 127.0.0.1 "$HTTP_PORT" /test-token \
    "$TEMP_ROOT/http-source" \
    "http://127.0.0.1:${HTTP_PORT}/test-token" \
    > "$TEMP_ROOT/http.log" 2>&1 &
HTTP_PID=$!
sleep 1
curl -fsS "http://127.0.0.1:${HTTP_PORT}/test-token" \
    -o "$TEMP_ROOT/http-result"
cmp "$TEMP_ROOT/http-source" "$TEMP_ROOT/http-result"
curl -fsS "http://127.0.0.1:${HTTP_PORT}/r" | \
    TMPDIR="$TEMP_ROOT" sh > "$TEMP_ROOT/http-short-result"
grep -q RECOVERY_HTTP_OK "$TEMP_ROOT/http-short-result"
kill "$HTTP_PID"
wait "$HTTP_PID" 2>/dev/null || true
HTTP_PID=

echo "Checking Python controller HTTP fallback..."
HTTP_PORT=$((HTTP_PORT + 1))
"$ROOT/src/httpd.py" 127.0.0.1 "$HTTP_PORT" /test-token \
    "$TEMP_ROOT/http-source" \
    "http://127.0.0.1:${HTTP_PORT}/test-token" \
    > "$TEMP_ROOT/http-python.log" 2>&1 &
HTTP_PID=$!
sleep 1
curl -fsS "http://127.0.0.1:${HTTP_PORT}/test-token" \
    -o "$TEMP_ROOT/http-python-result"
cmp "$TEMP_ROOT/http-source" "$TEMP_ROOT/http-python-result"
curl -fsS "http://127.0.0.1:${HTTP_PORT}/r" | \
    TMPDIR="$TEMP_ROOT" sh > "$TEMP_ROOT/http-python-short-result"
grep -q RECOVERY_HTTP_OK "$TEMP_ROOT/http-python-short-result"
kill "$HTTP_PID"
wait "$HTTP_PID" 2>/dev/null || true
HTTP_PID=

echo "Checking the loopback-only macOS nc listener form..."
LISTENER_PORT=$((20000 + $$ % 9000))
/usr/bin/nc -l 127.0.0.1 "$LISTENER_PORT" &
LISTENER_PID=$!
sleep 1
/usr/sbin/lsof -nP -a -iTCP:"$LISTENER_PORT" -sTCP:LISTEN |
    grep -q "127.0.0.1:${LISTENER_PORT}"
kill "$LISTENER_PID"
wait "$LISTENER_PID" 2>/dev/null || true
LISTENER_PID=

echo "Checking controller setup and self-extracting installer..."
printf '127.0.0.1 ssh-ed25519 TEST_HOST_KEY\n169.254.57.39 ssh-ed25519 TEST_USB_HOST_KEY\n192.0.2.10 ssh-ed25519 TEST_LAN_HOST_KEY\n' \
    > "$TEMP_ROOT/known_hosts"
touch "$TEMP_ROOT/authorized_keys"
RECOVERY_SSH_HOME="$TEMP_ROOT/state" \
RECOVERY_SSH_AUTHORIZED_KEYS="$TEMP_ROOT/authorized_keys" \
    "$ROOT/recovery-ssh" setup \
        --host 127.0.0.1 \
        --user testuser \
        --listen-port 24567 \
        --http-port 24568 \
        --host-key-file "$TEMP_ROOT/known_hosts" \
        > "$TEMP_ROOT/setup.out"

DEFAULT_STATE="$TEMP_ROOT/state/computers/default"
DEFAULT_TOKEN=$(sed -n "s/^TOKEN='\([^']*\)'$/\1/p" "$DEFAULT_STATE/config")
[ -n "$DEFAULT_TOKEN" ]
grep -q 'recovery-ssh-controller:default$' "$TEMP_ROOT/authorized_keys"
grep -q 'command="/usr/bin/nc -l 127.0.0.1 24567"' \
    "$TEMP_ROOT/authorized_keys"

mkdir "$TEMP_ROOT/data"
RECOVERY_SSH_VOLUME="$TEMP_ROOT/data" \
RECOVERY_SSH_REQUEST_RELOAD=1 \
RECOVERY_SSH_INSTALL_ONLY=1 \
    sh "$DEFAULT_STATE/install.sh" > "$TEMP_ROOT/install.out"

test -x "$TEMP_ROOT/data/recovery-ssh"
test -x "$TEMP_ROOT/data/.recovery-ssh/ptywrap"
test -r "$TEMP_ROOT/data/.recovery-ssh/id_ed25519"
test -e "$TEMP_ROOT/data/.recovery-ssh/reload"
cmp "$TEMP_ROOT/known_hosts" "$TEMP_ROOT/data/.recovery-ssh/known_hosts"

RECOVERY_SSH_HOME="$TEMP_ROOT/state" \
RECOVERY_SSH_AUTHORIZED_KEYS="$TEMP_ROOT/authorized_keys" \
    "$ROOT/recovery-ssh" setup \
        --host 127.0.0.1 \
        --user testuser \
        --listen-port 24567 \
        --http-port 24568 \
        --host-key-file "$TEMP_ROOT/known_hosts" \
        > "$TEMP_ROOT/setup-again.out"
REUSED_TOKEN=$(sed -n "s/^TOKEN='\([^']*\)'$/\1/p" "$DEFAULT_STATE/config")
[ "$REUSED_TOKEN" = "$DEFAULT_TOKEN" ]

echo "Checking multiple computer profiles and USB transport..."
RECOVERY_SSH_HOME="$TEMP_ROOT/state" \
RECOVERY_SSH_AUTHORIZED_KEYS="$TEMP_ROOT/authorized_keys" \
    "$ROOT/recovery-ssh" setup \
        --name m5-air \
        --transport usb \
        --host 169.254.57.39 \
        --user testuser \
        --host-key-file "$TEMP_ROOT/known_hosts" \
        > "$TEMP_ROOT/setup-usb.out"

USB_STATE="$TEMP_ROOT/state/computers/m5-air"
grep -q 'recovery-ssh-controller:m5-air$' "$TEMP_ROOT/authorized_keys"
grep -q 'command="/usr/bin/nc -l 127.0.0.1 2223"' \
    "$TEMP_ROOT/authorized_keys"
grep -q "^TRANSPORT='usb'$" "$USB_STATE/config"
grep -q "^LISTEN_PORT='2223'$" "$USB_STATE/config"
grep -q "^HTTP_PORT='8766'$" "$USB_STATE/config"
if cmp -s "$DEFAULT_STATE/id_ed25519" "$USB_STATE/id_ed25519"; then
    echo "computer profiles reused the same private key" >&2
    exit 1
fi

RECOVERY_SSH_HOME="$TEMP_ROOT/state" \
RECOVERY_SSH_AUTHORIZED_KEYS="$TEMP_ROOT/authorized_keys" \
    "$ROOT/recovery-ssh" list > "$TEMP_ROOT/list.out"
grep -q '^default' "$TEMP_ROOT/list.out"
grep -q '^m5-air' "$TEMP_ROOT/list.out"
grep -q 'usb' "$TEMP_ROOT/list.out"

RECOVERY_SSH_HOME="$TEMP_ROOT/state" \
RECOVERY_SSH_AUTHORIZED_KEYS="$TEMP_ROOT/authorized_keys" \
    "$ROOT/recovery-ssh" status --name m5-air > "$TEMP_ROOT/status-usb.out"
grep -q 'Computer:.*m5-air' "$TEMP_ROOT/status-usb.out"
grep -q 'Transport:.*usb' "$TEMP_ROOT/status-usb.out"

"$ROOT/recovery-ssh" usb-list > "$TEMP_ROOT/usb-list.out"
grep -q '^INTERFACE' "$TEMP_ROOT/usb-list.out"

mkdir "$TEMP_ROOT/usb-data"
RECOVERY_SSH_VOLUME="$TEMP_ROOT/usb-data" \
RECOVERY_SSH_INSTALL_ONLY=1 \
    sh "$USB_STATE/install.sh" > "$TEMP_ROOT/install-usb.out"
grep -q "COMPUTER_NAME='m5-air'" "$TEMP_ROOT/usb-data/recovery-ssh"
grep -q "TRANSPORT='usb'" "$TEMP_ROOT/usb-data/recovery-ssh"

echo "Checking automatic USB-to-LAN failover profile..."
RECOVERY_SSH_HOME="$TEMP_ROOT/state" \
RECOVERY_SSH_AUTHORIZED_KEYS="$TEMP_ROOT/authorized_keys" \
    "$ROOT/recovery-ssh" setup \
        --name failover-air \
        --transport auto \
        --usb-host 169.254.57.39 \
        --lan-host 192.0.2.10 \
        --user testuser \
        --host-key-file "$TEMP_ROOT/known_hosts" \
        > "$TEMP_ROOT/setup-auto.out"

AUTO_STATE="$TEMP_ROOT/state/computers/failover-air"
grep -q "^TRANSPORT='auto'$" "$AUTO_STATE/config"
grep -q "^USB_HOST='169.254.57.39'$" "$AUTO_STATE/config"
grep -q "^LAN_HOST='192.0.2.10'$" "$AUTO_STATE/config"
grep -q "TRANSPORT='auto'" "$AUTO_STATE/staging/recovery-ssh"
grep -q "USB_HOST='169.254.57.39'" "$AUTO_STATE/staging/recovery-ssh"
grep -q "LAN_HOST='192.0.2.10'" "$AUTO_STATE/staging/recovery-ssh"
grep -q 'USB unavailable; switching to Wi-Fi/LAN' \
    "$AUTO_STATE/staging/recovery-ssh"
grep -q 'HostKeyAlias="$CONTROLLER_HOST"' \
    "$AUTO_STATE/staging/recovery-ssh"
grep -q 'A U R O R A' "$AUTO_STATE/staging/recovery-ssh"
grep -q 'Secure recovery relay initialized' \
    "$AUTO_STATE/staging/recovery-ssh"
grep -q 'reload_if_requested' "$AUTO_STATE/staging/recovery-ssh"

echo "Checking launcher advances from failed USB to LAN..."
printf '%s\n' \
    '#!/bin/sh' \
    'for endpoint do :; done' \
    'case "$endpoint" in' \
    '    *169.254.57.39*) exit 255 ;;' \
    '    *192.0.2.10*)' \
    '        printf "echo AUTO_LAUNCHER_FAILOVER_OK; exit\\n"' \
    '        cat > "$RECOVERY_SSH_FAKE_LOG"' \
    '        ;;' \
    '    *) exit 254 ;;' \
    'esac' > "$TEMP_ROOT/fake-ssh"
chmod 700 "$TEMP_ROOT/fake-ssh"
RECOVERY_SSH_SSH="$TEMP_ROOT/fake-ssh" \
RECOVERY_SSH_FAKE_LOG="$TEMP_ROOT/launcher-failover.log" \
RECOVERY_SSH_NO_ANIMATION=1 \
    sh "$AUTO_STATE/staging/recovery-ssh" \
        > "$TEMP_ROOT/launcher.out" 2>&1 &
LAUNCHER_PID=$!
for _wait in 1 2 3 4 5; do
    grep -q AUTO_LAUNCHER_FAILOVER_OK \
        "$TEMP_ROOT/launcher-failover.log" 2>/dev/null && break
    sleep 1
done
if ! grep -q AUTO_LAUNCHER_FAILOVER_OK \
    "$TEMP_ROOT/launcher-failover.log" 2>/dev/null; then
    echo "launcher did not reach the LAN endpoint" >&2
    sed -n '1,120p' "$TEMP_ROOT/launcher.out" >&2
    exit 1
fi
grep -q 'USB unavailable; switching to Wi-Fi/LAN' \
    "$TEMP_ROOT/launcher.out"
kill "$LAUNCHER_PID"
wait "$LAUNCHER_PID" 2>/dev/null || true
LAUNCHER_PID=
cmp "$TEMP_ROOT/known_hosts" "$AUTO_STATE/staging/.recovery-ssh/known_hosts"
grep -q 'recovery-ssh-controller:failover-air$' "$TEMP_ROOT/authorized_keys"
grep -q "USB: curl.*169.254.57.39" "$TEMP_ROOT/setup-auto.out"
grep -q "LAN: curl.*192.0.2.10" "$TEMP_ROOT/setup-auto.out"

AUTO_LISTEN_PORT=$(sed -n "s/^LISTEN_PORT='\([0-9][0-9]*\)'$/\1/p" \
    "$AUTO_STATE/config")
[ -n "$AUTO_LISTEN_PORT" ]
[ "$AUTO_LISTEN_PORT" != 2223 ]

echo "Checking controller wait-and-reattach behavior..."
RECOVERY_SSH_HOME="$TEMP_ROOT/state" \
RECOVERY_SSH_AUTHORIZED_KEYS="$TEMP_ROOT/authorized_keys" \
    "$ROOT/recovery-ssh" connect --name failover-air \
        > "$TEMP_ROOT/connect-auto.out" 2>&1 &
CONNECT_PID=$!
sleep 2
kill -0 "$CONNECT_PID"
grep -q "Waiting for 'failover-air' Recovery shell" \
    "$TEMP_ROOT/connect-auto.out"
printf 'AUTO_REATTACH_OK\n' | \
    /usr/bin/nc -l 127.0.0.1 "$AUTO_LISTEN_PORT" &
LISTENER_PID=$!
for _wait in 1 2 3 4 5; do
    grep -q AUTO_REATTACH_OK "$TEMP_ROOT/connect-auto.out" && break
    sleep 1
done
grep -q AUTO_REATTACH_OK "$TEMP_ROOT/connect-auto.out"
kill -0 "$CONNECT_PID"
kill "$CONNECT_PID"
wait "$CONNECT_PID" 2>/dev/null || true
CONNECT_PID=
wait "$LISTENER_PID" 2>/dev/null || true
LISTENER_PID=

if RECOVERY_SSH_HOME="$TEMP_ROOT/state" \
    RECOVERY_SSH_AUTHORIZED_KEYS="$TEMP_ROOT/authorized_keys" \
    "$ROOT/recovery-ssh" setup \
        --name conflicting-mac \
        --host 127.0.0.1 \
        --user testuser \
        --listen-port 2223 \
        --host-key-file "$TEMP_ROOT/known_hosts" \
        > "$TEMP_ROOT/conflict.out" 2>&1; then
    echo "duplicate profile port was accepted" >&2
    exit 1
fi

echo "All Recovery SSH tests passed."
