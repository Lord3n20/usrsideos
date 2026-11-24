# UsrsideOS

A very small vibe-coded Linux system with its own linux-kernel that is
tailored to the machine during installation. It got made by vibe-coding a lot of improvements for gaming and laptop usage on Arch Linux and getting those to work on other Distros as well.

**Base system:** Arch Linux, Void Linux or Gentoo – the installer detects it from the ISO you boot.

**Preinstalled:** niri · kitty · ungoogled-chromium (Void: chromium) · hopd · iwd · usrkrnl,
plus the community package source of the base system (Arch: yay/AUR, Gentoo: GURU + pf4public overlays).
Everything else is picked in the installer (like archinstall) or installed later with the package manager.

## Install

Boot the ISO of the base system in **UEFI mode**, connect to the internet, then:

| ISO | Commands |
|---|---|
| Arch | `pacman -Sy --noconfirm git && git clone https://github.com/Lord3n20/usrsideos && usrsideos/install` |
| Void (glibc) | `xbps-install -Sy git && git clone https://github.com/Lord3n20/usrsideos && usrsideos/install` |
| Gentoo minimal | `wget https://github.com/Lord3n20/usrsideos/archive/main.tar.gz && tar xf main.tar.gz && usrsideos-main/install` |

Set disk, user etc. in the menu, then **Install**. The disk is erased completely:
1 GiB EFI partition and the rest as btrfs (`@`, `@home`, zstd compression).

| Menu entry | What happens |
|---|---|
| Autologin + niri | tty1 logs in by itself and starts niri |
| hopd | only the selected parts are compiled in; values (watts, brightness, panel) are asked for |
| Extra packages | sound, waybar, fuzzel, mako, lock screen, Bluetooth, NVIDIA … or your own packages (Arch: prefix `aur:` = AUR) |
| Build usrkrnl | kernel with only this machine's drivers, BORE, clang ThinLTO, no initramfs (10–40 min) |

| | Arch | Void | Gentoo |
|---|---|---|---|
| Init | systemd | runit | OpenRC |
| Bootstrap | pacstrap | xbps-install | stage3 (desktop-openrc) + binary packages |
| DNS / time | systemd-resolved / timesyncd | openresolv / chrony | openresolv / chrony |
| Install time | ~10 min | ~10 min | ~1 h+ (overlay packages are compiled) |

Everything distribution specific lives in `os/<id>.sh`; `install` itself is shared.
The installer keeps a copy of this repository in `~/usrsideos` for later rebuilds.
`fastfetch` shows the small UsrsideOS logo; the big one: `fastfetch --logo /usr/share/usrsideos/logo.txt --logo-color-1 37 --logo-color-2 96`.

Unattended installs (for tests): `install --answers FILE`, where FILE sets `DISK`, `USERNAME`, `PASSWORD`
and optionally any other variable from the top of `install` (e.g. `USRKRNL=0`).

## Booting

- The distribution kernel (with initramfs) is always there as the fallback entry
  "UsrsideOS (linux|void|gentoo kernel)"; a kernel hook keeps it under a fixed name in `/boot`.
- The first reboot uses usrkrnl **once**. If it boots, `usrkrnl-confirm` makes it the default.
  If it does not, the next boot uses the distribution kernel again.
- New hardware later? Plug the device in, use it, then run `~/usrsideos/usrkrnl/setup`.
- Kernel update: `git -C ~/usrsideos pull && ~/usrsideos/usrkrnl/setup`.

## usrkrnl

Upstream Linux stable plus the BORE scheduler, configured and built per machine
by [`usrkrnl/setup`](usrkrnl/setup). Details: [usrkrnl/README.md](usrkrnl/README.md).

## hopd

A small daemon in C (dwm style: settings in `config.h`, parts in `patches.h`, rebuild with `make`).
Installed to `/usr/local/src/hopd`. Its commands and config names are German.

| Part | Purpose |
|---|---|
| strom | profiles for AC / battery / battery with eGPU: RAPL power, EPP, turbo, ASPM, brightness, USB and PCI power saving |
| akkulog | log battery drain, summary with `akku-log report` |
| luefter | fan curves, TUXEDO InfinityBook Pro Gen9 only |
| egpu | wake a Thunderbolt eGPU, log disconnects |
| niri | lid, refresh rate on AC/battery, waybar start, locking |

Commands: `hopd befehle`; to change settings, edit `/usr/local/src/hopd/config.h`, then
`sudo make -C /usr/local/src/hopd install && sudo systemctl restart hopd`.

## Limits

- x86_64 with UEFI only. Void: glibc only. Gentoo: OpenRC only. No disk encryption (usrkrnl boots without initramfs).
- The installer erases the chosen disk completely, no dual boot.
