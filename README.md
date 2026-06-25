# x-chip-tinycore

TinyCore Linux image builder for NextThing CHIP / PocketCHIP.

It builds one flashable rootfs tar:

```sh
headless-rootfs.tar.gz
```

Target:

- TinyCore/CorePure armhf 16.x
- Linux `6.18.36-chip-tc`
- NAND/UBIFS boot through `x-chip-tools`
- LCD console, serial console, WiFi, SSH
- no Xorg, no desktop

## Current Status

Tested on a PocketCHIP:

- FEL flash to NAND
- LCD console
- PocketCHIP keyboard
- internal RTL8723BS WiFi
- SSH login as `chip`
- RTL8812AU USB WiFi module built as optional secondary adapter

## Quick Flash

This erases the PocketCHIP NAND rootfs.

1. Put CHIP/PocketCHIP in FEL mode: connect **FEL** to **GND**.
2. Plug USB into the Linux flashing machine.
3. Build or download `headless-rootfs.tar.gz`.
4. Flash.

Local USB flash:

```sh
make flash-local
```

USB connected to another Linux host over SSH:

```sh
FLASH_HOST=my-linux-host make flash-host
```

When the script says flash is complete, remove the FEL jumper and reboot.

## Personal Build

Use this when the device should join your WiFi and accept your SSH key:

```sh
make deps
cp secrets.env.example secrets.env
$EDITOR secrets.env
make container-build
make verify
```

The rootfs assembler must preserve root-owned files, setuid bits, and static
console device nodes. Use `make container-build` for the normal path; local
non-root builds require `fakeroot`.

Then flash:

```sh
make flash-local
```

or:

```sh
FLASH_HOST=my-linux-host make flash-host
```

## Public Build

Use this for a GitHub release asset:

```sh
make deps
make public-rootfs
make public-verify
make public-release
```

The public image contains no WiFi PSK and no SSH authorized key.
SSH is enabled with password login for user `chip`; the default public password
is `chip`. Change it after first login with `passwd`, or override it at build
time with `SSH_PASSWORD=... make public-rootfs`.

## Important Files

```text
config.env                 build defaults
boot/boot.cmd              U-Boot NAND boot script
kernel/sun5i-chip.config   PocketCHIP kernel fragment
tce/onboot.lst             TinyCore extensions installed at boot
scripts/00-fetch-deps.sh   fetch chip-debroot and x-chip-tools
scripts/03-assemble-rootfs.sh
scripts/05-flash-local.sh
scripts/05-flash-via-host.sh
scripts/07-verify-rootfs.sh
scripts/08-package-release.sh
```

## Defaults

- Hostname: `chip`
- User: `chip`
- LCD brightness: `LCD_BRIGHTNESS=6`
- Internal WiFi: RTL8723BS
- External USB WiFi: RTL8812AU loads only when plugged in
- PocketCHIP keymap: loaded from `chip-debroot` by default
- Audio UI controls: `libasound.tcz` + `alsa.tcz` + `alsa-utils.tcz` loaded
  early for direct ALSA control (`amixer`, `alsamixer`, `aplay`)
- Optional media pack: `/tce/media.lst` pre-seeds `ffmpeg.tcz`; it is loaded on
  demand by `x-chip-media-on` for `ffplay` video playback, not at boot

The PocketCHIP keymap is a partial `loadkeys` overlay. The build always merges
it with the default Linux console map from the kernel tree being built, then
converts the complete result to BusyBox `loadkmap` format. Converting the
PocketCHIP overlay by itself is rejected because it breaks normal letter and
number keys.

## Local Secrets

Do not publish personal images. They can contain:

- `/etc/wpa_supplicant.conf`
- `/home/chip/.ssh/authorized_keys`
- SSH host keys

Ignored by git:

- `secrets.env`
- `build/`
- `headless-rootfs.tar.gz`
- `dist/`
- private keys, logs, local build outputs

Use `docs/RELEASE.md` before publishing.

## Manual Commands

Change LCD brightness on a running PocketCHIP:

```sh
echo 6 | sudo tee /sys/class/backlight/backlight/brightness
```

Check board status:

```sh
x-chip-keyboard-status
x-chip-audio-status
x-chip-power-status
```

Flash a downloaded tar directly:

```sh
./scripts/05-flash-local.sh --rootfs ./headless-rootfs.tar.gz --flash
```
