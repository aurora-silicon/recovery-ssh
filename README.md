# Recovery SSH

Recovery SSH provides a persistent, interactive shell for macOS Recovery even
when Recovery does not contain `sshd` or `ssh-keygen`. The Recovery Mac makes an
outbound SSH connection to a controller Mac, and the controller exposes that
shell only on `127.0.0.1`.

One controller can manage multiple Recovery Macs concurrently. Every named Mac
profile has its own restricted key, installer, HTTP port, shell port, and state.
Profiles may use the normal LAN, the USB cable's CDC-NCM network link, or an
automatic USB-first mode with LAN/Wi-Fi failover.

The project is designed for both Apple silicon and Intel Recovery. Its PTY helper
is a universal Mach-O binary. The controller may run macOS or Linux; automatic
Apple USB-NCM discovery is macOS-only, while Linux supports LAN and explicit
USB endpoint configuration.

## What persists

The installer places the launcher, a dedicated restricted SSH key, the pinned
controller host keys, and the PTY helper on every writable APFS Data volume it
finds. Signed Recovery cannot automatically start third-party programs, so one
short command is still required after every Recovery reboot.

## Quick start

On the controller Mac:

1. Enable **System Settings → General → Sharing → Remote Login** for the current
   user.
2. Run:

   ```sh
   cd /path/to/recovery-ssh
   ./recovery-ssh start --name my-mac
   ```

3. The command prints a single `curl` command. Run that command in the target
   Mac's Recovery Terminal.
4. Leave the Recovery Terminal open. The controller automatically attaches when
   the reverse shell is ready.

For later Recovery sessions, run the persistent command printed by the installer,
normally:

```sh
sh /Volumes/Data/recovery-ssh
```

Then attach from the controller with:

```sh
./recovery-ssh connect --name my-mac
```

You never need to type another installer `curl` after the first installation.
To push a newer local build, launch the existing persistent command and run the
host-side updater:

```sh
# Recovery Mac
sh /Volumes/Data/recovery-ssh

# Controller Mac
./recovery-ssh update --name my-mac
```

The updater transfers and overwrites the persistent launcher through the active
Recovery shell. Installer URLs also retain the same per-computer token across
rebuilds, and the temporary server exposes `/r` as a short emergency bootstrap
path.

Omitting `--name` continues to use the backward-compatible `default` profile.

## Multiple computers

Give each Mac a stable name. Ports are allocated automatically without colliding
with other configured profiles:

```sh
# Terminal 1: Recovery shell for the MacBook Air over USB
./recovery-ssh start --name m5-air --transport usb

# Terminal 2: Recovery shell for a Mac mini over the LAN
./recovery-ssh start --name lab-mini --transport lan

# Show every configured Mac and whether its shell is waiting
./recovery-ssh list
```

Each `start` command can remain open in its own controller Terminal window. To
attach to an already waiting Mac, use:

```sh
./recovery-ssh connect --name m5-air
```

Explicit `--listen-port` and `--http-port` values are supported, but the command
rejects a port already assigned to another profile.

## Shell over USB

Apple Recovery exposes a CDC-NCM network interface over a direct USB-C cable.
USB mode detects the active `AppleUSBNCMData` interface, uses its link-local IPv4
address for the installer URL, and routes the reverse SSH session over that cable:

```sh
./recovery-ssh start --name m5-air --transport usb
```

If several Recovery Macs are attached, select the controller interface shown by
`ifconfig`:

```sh
./recovery-ssh start --name m5-air --transport usb --usb-interface en21
```

You can also provide the controller's USB link-local address directly with
`--host`. USB shell mode is network-over-USB and works with USB 2 or USB 3 cables;
it is separate from macvdmtool's SuperSpeed serial mode and does not require
`iproxy`.

## Automatic USB-to-Wi-Fi failover

Use `auto` mode when the Recovery Mac and controller are on the same LAN and a
USB data cable is also connected:

```sh
./recovery-ssh start --name m5-air --transport auto
```

The generated Recovery launcher pins the controller identity across both
endpoints. It tries the USB-NCM endpoint first and falls back to the controller's
normal LAN/Wi-Fi address whenever USB becomes unavailable. The controller-side
`start` and `connect` commands remain open, wait through disconnects, and
automatically attach to the replacement shell when it appears.

A failover starts a new Recovery shell process, so unsaved interactive shell
state such as the current directory is not preserved. A healthy Wi-Fi session
is not interrupted merely because USB returns; USB becomes preferred again on
the next reconnect. Use `--usb-host` and `--lan-host` to pin explicit addresses
when automatic interface discovery is not appropriate.

## Commands

```text
./recovery-ssh start     Prepare, serve, wait, and attach
./recovery-ssh setup     Generate the key, bundle, and installer
./recovery-ssh serve     Serve the generated installer
./recovery-ssh connect   Attach to the loopback-only Recovery shell
./recovery-ssh update    Push an update through a connected Recovery shell
./recovery-ssh status    Check one named Mac profile
./recovery-ssh list      List all configured Recovery Macs
./recovery-ssh usb-list  List connected Mac USB-NCM interfaces
./recovery-ssh doctor    Check build and controller dependencies
```

Common setup/start options:

```text
--name NAME             Select a Mac profile (default: default)
--transport lan|usb|auto Choose the path; auto prefers USB and falls back to LAN
--usb-interface NAME    Select a controller USB-NCM interface
--host ADDRESS          Controller address reachable from Recovery
--usb-host ADDRESS      Explicit controller USB endpoint for auto mode
--lan-host ADDRESS      Explicit controller LAN/Wi-Fi endpoint for auto mode
--user USER             Controller Remote Login user
--listen-port PORT      Controller loopback shell port (default: 2222)
--http-port PORT        Temporary installer HTTP port (default: 8765)
--host-key-file PATH    Use a pre-collected known_hosts file
```

Per-computer state is stored in `~/.recovery-ssh/computers/NAME` by default. Set
`RECOVERY_SSH_HOME` to use a different base location. Legacy single-computer
state at `~/.recovery-ssh` remains usable as the `default` profile. The short
emergency bootstrap is safe to pipe because `/r` serves a small downloader that
saves the self-extracting installer to `/tmp` before executing it:

```sh
curl CONTROLLER:PORT/r | sh
```

## Security model

- A dedicated key is generated for each Recovery Mac; no personal SSH key is
  copied and profiles never share private keys.
- Its `authorized_keys` entry is restricted to a forced, loopback-only `nc`
  listener. It cannot request a controller shell, PTY, agent forwarding, or port
  forwarding.
- Controller host keys are pinned before the bundle is created. The launcher
  uses `accept-new` against only that dedicated file so Recovery OpenSSH can
  record a key it fails to recognize from the preload; changed keys remain
  rejected.
- The temporary HTTP URL includes a random token. Stop the server after install.
- The Recovery private key persists on the selected Data volume with mode `0600`.

Anyone who can unlock or mount that Data volume can recover the restricted key.
Remove its `recovery-ssh-controller:NAME` line from the controller's
`~/.ssh/authorized_keys` to revoke access.

## Build and test

Xcode Command Line Tools are needed to rebuild the helpers:

```sh
make release
make test
```

The release build produces universal `arm64`/`x86_64` binaries in `dist/`.

For a Linux controller, first copy a macOS release tree so `dist/ptywrap` is
present. The installer server uses Python 3 when no native build toolchain is
available; `make controller-httpd` remains available for a native C helper.
Use LAN or an explicit USB host:

```sh
./recovery-ssh doctor
./recovery-ssh start --name neo-j700 --transport lan --host 10.1.1.131
```
