# x-chip-tinycore (moved)

This project has moved to
**[x-chip-tinycore-xorg](https://github.com/marceloeatworld/x-chip-tinycore-xorg)**.

The new repository builds two images for the NextThing CHIP / PocketCHIP from
one source tree, with a modern mainline kernel, WiFi, SSH, and over-the-air
updates (`sudo x-chip-update`):

- the Xorg/JWM desktop image (default, published as releases)
- a headless image, same base system without the desktop:
  `make headless-rootfs`

The headless image previously built here is superseded by the headless
variant there. It adds everything this repository never had: in-place updates
without reflashing, both PocketCHIP keyboard revisions (v72/v73), HDMI/VGA
DIP auto-detection, boot-time clock sync, and all later fixes.

The old `v0.1.x` releases of this repository have been removed. Flash or
build current images from the new repository:

```sh
git clone https://github.com/marceloeatworld/x-chip-tinycore-xorg.git
cd x-chip-tinycore-xorg
./scripts/flash-release-pocketchip.sh --install-deps
```
