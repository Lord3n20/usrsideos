# UsrsideOS

A very small vibe-coded Linux system with its own linux-kernel that is
tailored to the machine during installation. It got made by vibe-coding a lot of improvements for gaming and laptop usage on Arch Linux and getting those to work on other Distros as well.

**Base system:** Arch Linux, Void Linux, Gentoo or Alpine Linux – the installer detects it from the ISO you boot.

> **Gentoo and Alpine are experimental and untested.** Arch and Void have passed full test installations;
> on a Gentoo or Alpine ISO the installer asks before it continues.

**Always installed:** base system, kernel + firmware + microcode, sudo, efibootmgr, git, the tools of the
root filesystem and the network (iwd for Wi-Fi, DHCP for cable). Everything else is chosen in the
installer, starting from a profile (see [Default selection](#default-selection)).

## Install

Boot the ISO of the base system in **UEFI mode**, connect to the internet, then:

| ISO | Commands |
|---|---|
| Arch | `pacman -Sy --noconfirm git && git clone https://github.com/Lord3n20/usrsideos && usrsideos/install` |
| Void (glibc) | `xbps-install -Sy git && git clone https://github.com/Lord3n20/usrsideos && usrsideos/install` |
| Gentoo minimal (experimental) | `wget https://github.com/Lord3n20/usrsideos/archive/main.tar.gz && tar xf main.tar.gz && usrsideos-main/install` |
| Alpine standard (experimental) | log in as `root`, then `setup-interfaces -r && setup-apkrepos -c1 && apk add bash git && git clone https://github.com/Lord3n20/usrsideos && usrsideos/install` (setup-interfaces also asks for Wi-Fi) |

Set disk, user etc. in the menu, then **Install**. The disk is erased completely:
1 GiB EFI partition and the rest as the root filesystem (default btrfs with `@`, `@home`, zstd, see below).

| Menu entry | What happens |
|---|---|
| Profile | `minimal` (default) or `desktop`, presets everything below |
| Autologin + niri | tty1 logs in by itself and starts niri (needs the niri desktop) |
| hopd | only the selected parts are compiled in; values (watts, brightness, panel) are asked for |
| Packages | every option on its own (see the table below), plus your own packages (Arch: prefix `aur:` = AUR) |
| Filesystem | btrfs (subvolumes, compression) or XFS, see [Filesystem](#filesystem) |
| Build usrkrnl | kernel with only this machine's drivers, BORE, clang ThinLTO, no initramfs (10–40 min) |

| | Arch | Void | Gentoo | Alpine |
|---|---|---|---|---|
| Init | systemd | runit | OpenRC | OpenRC |
| libc | glibc | glibc | glibc | musl |
| Bootstrap | pacstrap | xbps-install | stage3 (desktop-openrc) + binary packages | apk --root (main + community) |
| Kernel / initramfs | linux / mkinitcpio | linux / dracut | gentoo-kernel-bin / dracut | linux-lts / mkinitfs |
| DNS / time | systemd-resolved / timesyncd | openresolv / chrony | openresolv / chrony | openresolv / chrony |
| Install time | ~10 min | ~10 min | ~1 h+ (overlay packages are compiled) | ~10 min |

Everything distribution specific lives in `os/<id>.sh`; `install` itself is shared.
The installer keeps a copy of this repository in `~/usrsideos` for later rebuilds.
`fastfetch` shows the small UsrsideOS logo; the big one: `fastfetch --logo /usr/share/usrsideos/logo.txt --logo-color-1 37 --logo-color-2 96`.

Defaults are a German setup: `KEYMAP=de-latin1`, `LOCALE=de_DE.UTF-8`, `TIMEZONE=Europe/Berlin`; change them in the menu or set them in the answers file.

Unattended installs (for tests): `install --answers FILE`, where FILE sets `DISK`, `USERNAME`, `PASSWORD`
and optionally any other variable from the top of `install` (e.g. `USRKRNL=0`). `PROFILE=minimal|desktop`
presets the rest; single options override it with their key in capitals and `0`/`1` (`DESKTOP=1`,
`BROWSER=0`, `YAY=1` or `AUR=1`, …), as do `AUTOLOGIN`, `USRKRNL` and `H_*`.

## Default selection

| Profile | After the reboot |
|---|---|
| `minimal` (default) | text login on tty1, network; no autologin, no hopd, no usrkrnl, no options |
| `desktop` | the UsrsideOS desktop: autologin into niri, hopd (parts by hardware, niri part on), all options marked ✓ below; usrkrnl stays off (build time) |

Every option can be switched on its own; what an option needs is switched on automatically
(waybar, rofi, mako, lock screen, polkit agent and swaybg need the niri desktop, the PulseAudio Bluetooth
module needs sound and Bluetooth, AUR packages need yay). Answers-file key = the key in capitals.

| Key | Option | `desktop` | Arch | Void | Gentoo (untested⁴) | Alpine |
|---|---|---|---|---|---|---|
| `desktop` | niri, kitty, xwayland-satellite, xdg-desktop-portal-gnome, wl-clipboard, Noto/DejaVu/Liberation fonts | ✓ | ✓ | ✓ | ✓ | ✓ |
| `waybar` | top bar | ✓ | ✓ | ✓ | ✓ | ✓ |
| `rofi` | app launcher on Mod+Space (replaces fuzzel on Mod+D) | ✓ | ✓ | ✓ | ✓ | ✓ |
| `mako` | notifications | ✓ | ✓ | ✓ | ✓ | ✓ |
| `lock` | lock screen on Mod+L + idle lock after 10 min, see [niri keys](#niri-keys) | ✓ | swaylock + swayidle | swaylock + swayidle | swaylock + swayidle | swaylock + swayidle |
| `polkit` | polkit agent | ✓ | hyprpolkitagent | polkit-gnome¹ | polkit-gnome¹ | polkit-gnome¹ |
| `swaybg` | plain wallpaper colour | ✓ | ✓ | ✓ | ✓ | ✓ |
| `sound` | PulseAudio + pulsemixer (+ sof-firmware) | ✓ | ✓ | ✓ | ✓ | ✓ |
| `bluetooth` | bluez, service enabled | ✓ | ✓ | ✓ | ✓ | ✓ |
| `sound_bt` | PulseAudio Bluetooth module | ✓ | ✓ | –² | –² | ✓ |
| `ssh` | OpenSSH (server not enabled) | ✓ | ✓ | ✓ | ✓ | ✓ |
| `wireguard` | WireGuard tools | ✓ | ✓ | ✓ | ✓ | ✓ |
| `neovim` `btop` `fastfetch` `bashcomp` `fzf` `tmux` `less` `unzip` `wget` | one option each | ✓ | ✓ | ✓ | ✓ | ✓ |
| `pkgtools` | pacman-contrib + weekly paccache.timer | ✓ | ✓ | – | – | – |
| `mpv` `zathura` `feh` | video, PDF, images | ✓ | ✓ | ✓ | ✓ | ✓ |
| `browser` | ungoogled-chromium (Void, Alpine: chromium) | ✓ | AUR | ✓ | pf4public | ✓ |
| `yay` | AUR helper | ✓ | ✓ | – | – | – |
| `intel_media` `nvidia` `bolt` `tuxedo` | Intel video acceleration, NVIDIA driver, Thunderbolt, TUXEDO drivers | if detected | ✓ (tuxedo: AUR) | ✓ | ✓ (no tuxedo) | intel_media, bolt⁵ |
| `printing` | CUPS + system-config-printer + simple-scan | | ✓ | ✓ | ✓ | ✓ |
| `fish` `office` `latex` | fish shell, LibreOffice, TeX Live base | | ✓ | ✓ | ✓ | ✓ |
| `games` | Steam + MangoHud (enables multilib) | | ✓ | –³ | –³ | –⁶ |

¹ hyprpolkitagent is not packaged for Void and needs systemd --user (Gentoo and Alpine use OpenRC).
² part of PulseAudio itself (Void) or its `bluetooth` USE flag (Gentoo).
³ Steam needs the multilib repositories (Void) or the steam-overlay (Gentoo); set them up yourself.
⁴ the Gentoo package atoms are checked in the Gentoo test phase.
⁵ Alpine has no NVIDIA driver (glibc only; nouveau/NVK come with mesa) and the TUXEDO drivers only as a source package.
⁶ Steam needs glibc.

### niri keys

UsrsideOS changes a few keys of niri's default config:

| Key | Default niri | UsrsideOS |
|---|---|---|
| Mod+Space | (switch keyboard layout, commented out) | app launcher (rofi), with `rofi` |
| Mod+D | app launcher (fuzzel) | focus column right, with `lock` |
| Mod+A | – | focus column left, with `lock` |
| Mod+L | focus column right | lock screen, with `lock` (Mod+Right still moves right) |
| Super+Alt+L | swaylock | moved to Mod+L (`swaylock -f -c 1e2030`, also for the idle lock) |

Sound is PulseAudio. PipeWire may still come in as a dependency of the portal (screen sharing), but
WirePlumber is configured not to touch the sound cards and nothing provides the pulse socket.
Arch starts PulseAudio through its systemd user socket, Void, Gentoo and Alpine with the niri session (or on
demand through autospawn).

## Filesystem

The EFI partition is always vfat. For the root partition you choose in the menu (or in the answers file):

| Setting | Values | Default |
|---|---|---|
| `FS` | `btrfs`, `xfs` | `btrfs` |
| `BTRFS_SUBVOLS` | besides `@` (root) any of `@home` `@var_log` (/var/log) `@cache` (/var/cache) `@snapshots` (/.snapshots), or `flat` for no subvolumes | `@home` |
| `BTRFS_COMPRESS` | `zstd:1` … `zstd:15`, `lzo`, `none` | `zstd:1` |

Mount options are always `noatime`; btrfs also gets `discard=async` on SSDs (`lsblk` ROTA 0).
Only the tools of the chosen filesystem are installed (btrfs-progs or xfsprogs).
usrkrnl has no initramfs, so it builds the root filesystem into the kernel (`CONFIG_BTRFS_FS=y` or `CONFIG_XFS_FS=y`).

## Booting

- The distribution kernel (with initramfs) is always there as the fallback entry
  "UsrsideOS (linux|void|gentoo|alpine kernel)"; a kernel hook keeps it under a fixed name in `/boot`
  (with usrkrnl only during the installation, see below).
- `/boot` is the 1 GiB EFI partition. Void and Gentoo get a host-only initramfs, and their kernel
  hook removes old kernels (Void: those no package owns any more, Gentoo: all but the two newest);
  the running kernel always stays. On Void do not run `vkpurge rm all`: it would also delete the
  fixed-name copy `vmlinuz-void` (the next kernel update creates it again).
- Alpine keeps one kernel per flavour anyway. Its hook (`/etc/kernel-hooks.d/50-usrside.hook`) also
  builds the initramfs with mkinitfs (only the drivers for the root filesystem, no host-only mode) and
  puts the CPU microcode in front of it; a microcode update alone is picked up with the next kernel
  update (or `apk fix linux-lts`).
- The first reboot uses usrkrnl **once**. If it boots, `usrkrnl-confirm` makes it the default
  (BootOrder: usrkrnl, then the distribution kernel). If it does not, the next boot uses the
  distribution kernel again.
- With usrkrnl the distribution kernel is a **frozen emergency backup from the installation**: it is
  not updated any more and no initramfs is generated again, not even by firmware or other package
  updates (`linux-firmware` keeps being updated). Held: Arch `IgnorePkg = linux linux-headers` in
  `/etc/pacman.conf` (mkinitcpio hooks off in `/etc/pacman.d/hooks`), Void `xbps-pkgdb -m hold`
  on the `linux*` packages, Gentoo `/etc/portage/package.mask/usrside-kernel` (plus
  `-dist-kernel -initramfs` for linux-firmware/intel-microcode), Alpine `linux-lts=<version>` in
  `/etc/apk/world`. Boot it once with `sudo efibootmgr -n XXXX` (XXXX = the fallback entry).
  If neither kernel boots any more: the live USB stick. Without usrkrnl (or if its build failed)
  the distribution kernel is updated as usual.
- After a BIOS reset (UEFI boot entries lost) the firmware starts `\EFI\BOOT\BOOTX64.EFI`:
  usrkrnl/setup puts a copy of usrkrnl there (it needs no arguments, the command line is built in),
  unless another system or bootloader already uses that path. The distribution kernel needs its
  entry (initramfs + command line). Without usrkrnl, recreate it from the live USB stick:
  `efibootmgr -c -d /dev/DISK -p 1 -L "UsrsideOS" -l '\vmlinuz-NAME' -u "root=PARTUUID=… rw initrd=\initramfs-NAME.img"`
  (the old command line: `cat /proc/cmdline` on the running system).
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

## Pure UsrsideOS (experimental)

Booted from the UsrsideOS live system (for now a glibc image of the rcyay bootstrap, later the live ISO),
`install` uses the backend `os/usrside.sh`: no Arch ISO, everything comes from the live system (rcyay, pacman,
the repository `[usrside]` in `/srv/usrside`, the running kernel). Packages are Arch binary packages
(core/extra/multilib) plus `[usrside]`, installed with `rcyay --root` instead of pacstrap; the keyring of the new
system is initialised by the installer. No Flatpak/Snap.

| Key (menu "Init/libc") | Values | Default |
|---|---|---|
| `INIT` | `runit`, `s6`, `busybox`, `systemd` (services of all four are installed, `init=` in the boot entries, `Init =` in `/etc/rcyay.conf`; switch later with `rcyay --init NAME`) | `runit` |
| `PROFIL` | `standard` (GNU tools stay), `minimal` (BusyBox instead of coreutils/findutils/grep/sed/gawk/diffutils) | `standard` |
| `LIBC` | `glibc`; `musl` (repository `usrside-musl` of the live medium: BusyBox userland, niri + foot, PipeWire; no systemd, AUR, usrkrnl/NVIDIA; options without musl packages drop out) | `glibc` |

- Without systemd: seatd (niri with `LIBSEAT_BACKEND=seatd`, the user is in the group `seat`), an own D-Bus
  system bus service, `XDG_RUNTIME_DIR` from `/etc/usrside/start.d`, the polkit agent is polkit-gnome, PulseAudio
  starts with niri; other services are translated from their systemd units by rcyay.
- Fallback boot entry "UsrsideOS (live kernel)": the kernel of the live system without initramfs.
  NVIDIA and TUXEDO drivers switch usrkrnl on (their DKMS modules are built against usrkrnl).
- `install --print-packages [OPTION …]` (no root, no network) prints every package any variant may install
  (`repo NAME` / `aur NAME`; all inits, usrkrnl, all options except the named ones), for the live medium's mirror.
- AUR packages (`aur:`, browser, TUXEDO) are built with rcyay. From the live ISO, packages that lie finished
  on the medium (repository `usrside-aur` under `/run/usrside/quelle`) are installed from there; without network
  the rest is skipped with a note. The medium's offline mirror (`file://` lines) is not taken into the
  mirrorlist of the new system.

## Limits

- x86_64 with UEFI only. Void: glibc only. Gentoo: OpenRC only. Alpine: Wi-Fi of the live ISO (wpa_supplicant) is not taken over, use `iwctl` after the reboot. No disk encryption (usrkrnl boots without initramfs).
- The installer erases the chosen disk completely, no dual boot.
