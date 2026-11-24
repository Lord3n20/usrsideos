# UsrsideOS

A very small Arch Linux system with its own kernel ([usrkrnl](usrkrnl/)) that is
tailored to the machine during installation.

**Preinstalled:** yay · niri · kitty · ungoogled-chromium · hopd · iwd · usrkrnl.
Everything else is picked in the installer (like archinstall) or installed later with `pacman`/`yay`.

## Install

Boot the Arch Linux ISO in **UEFI mode**, then:

```sh
iwctl station wlan0 connect MY-WIFI     # Wi-Fi only
pacman -Sy --noconfirm git
git clone https://github.com/Lord3n20/usrsideos
usrsideos/install
```

Set disk, user etc. in the menu, then **Install**. The disk is erased completely:
1 GiB EFI partition and the rest as btrfs (`@`, `@home`, zstd compression).

| Menu entry | What happens |
|---|---|
| Autologin + niri | tty1 logs in by itself and starts `niri-session` |
| hopd | only the selected parts are compiled in; values (watts, brightness, panel) are asked for |
| Extra packages | sound, waybar, fuzzel, mako, lock screen, Bluetooth, NVIDIA … or your own packages (prefix `aur:` = AUR) |
| Build usrkrnl | kernel with only this machine's drivers, BORE, clang ThinLTO, no initramfs (10–40 min) |

The installer keeps a copy of this repository in `~/usrsideos` for later rebuilds.

## Booting

- The Arch kernel (with initramfs) is always there as the fallback entry "UsrsideOS (Arch kernel)".
- The first reboot uses usrkrnl **once**. If it boots, `usrkrnl-confirm` makes it the default.
  If it does not, the next boot uses the Arch kernel again.
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

- x86_64 with UEFI only. No disk encryption (usrkrnl boots without initramfs).
- The installer erases the chosen disk completely, no dual boot.
