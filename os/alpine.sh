# UsrsideOS installer backend: Alpine Linux (musl, OpenRC, booted from the Alpine standard ISO).
# Sourced by ../install, see the contract there.
#
# The live system needs a network mirror first (setup-interfaces, setup-apkrepos -c1), then
# bash and git for the installer itself. The target uses main + community of the same release.

# shellcheck disable=SC2034  # contract variables of this file are used by ../install
OS_NAME="Alpine Linux"
OS_KERNEL_NAME=alpine         # fallback entry: \vmlinuz-alpine + \initramfs-alpine.img (written by a kernel hook)
FREE_HINT="Alpine package names (main + community), e.g. firefox gimp"
COMMUNITY="none needed: everything comes from Alpine main + community"
SSH_PKG=openssh
SESSION_CMD="exec dbus-run-session niri --session"
IWD_DNS=resolvconf
ALPINE_MIRROR=https://dl-cdn.alpinelinux.org/alpine
# same release as the live ISO (VERSION_ID 3.24.4 -> v3.24); a snapshot/edge ISO installs edge
ALPINE_BRANCH=$(. /etc/os-release 2>/dev/null; v=${VERSION_ID:-}
	if [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "v${v%.*}"; else echo edge; fi)
KFLAVOR=lts                   # linux-lts: Alpine's default kernel, in main (linux-stable is in community)

# always: a bootable system with network; the rest only when chosen (see install: packages)
# eudev instead of mdev (libinput/niri need udev); shadow-login = login with PAM, so pam_elogind
# registers the session (XDG_RUNTIME_DIR, seat); kbd-legacy has the console keymaps (de-latin1 …)
BASE=(alpine-base "linux-$KFLAVOR" linux-firmware mkinitfs kernel-hooks eudev dosfstools sudo
	iwd openresolv dhcpcd dbus elogind chrony git efibootmgr bash shadow shadow-login agetty
	runuser curl tzdata kbd kbd-legacy musl-locales)
BROWSER_NAME=chromium
POLKIT_SPAWN='"/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1"'   # hyprpolkitagent needs systemd --user
BUILD_PKGS=(build-base linux-headers)   # compiler + make; hopd needs the kernel headers (netlink)
KERNEL_PKGS=(clang lld llvm bc flex bison perl openssl openssl-dev elfutils-dev zstd patch xz coreutils sed grep
	cpio diffutils findutils findmnt blkid lsblk kmod iucode-tool python3)   # usrkrnl only; GNU coreutils/sed/grep: kernel scripts (readlink -m, grep --include); python3: initcall order with ThinLTO
FS_PKG_btrfs=btrfs-progs
FS_PKG_xfs=xfsprogs
UCODE_INTEL=intel-ucode
UCODE_AMD=amd-ucode

# packages per option (see OPTIONS in install). Not offered on Alpine: pacman tools, yay, games
# (Steam needs glibc), the NVIDIA driver (glibc; nouveau/NVK come with mesa), TUXEDO drivers
# (only as source package). Everything else is in main or community, nothing from edge/testing.
declare -A PKG=(
	[desktop]="niri kitty xwayland-satellite xwayland xdg-desktop-portal-gnome wl-clipboard mesa-dri-gallium font-noto font-noto-cjk font-noto-emoji font-dejavu font-liberation"
	[waybar]=waybar [rofi]=rofi-wayland [mako]=mako [lock]="swaylock swayidle" [polkit]="polkit-gnome polkit-elogind" [swaybg]=swaybg
	[sound]="pulseaudio pulseaudio-utils pulseaudio-alsa alsa-plugins-pulse pulsemixer sof-firmware" [sound_bt]=pulseaudio-bluez
	[bluetooth]=bluez [ssh]=openssh-client-default [wireguard]=wireguard-tools
	[neovim]=neovim [btop]=btop [fastfetch]=fastfetch [bashcomp]=bash-completion [fzf]=fzf [tmux]=tmux
	[less]=less [unzip]=unzip [wget]=wget
	[mpv]=mpv [zathura]="zathura zathura-pdf-poppler" [feh]=feh
	[browser]=chromium
	[intel_media]=intel-media-driver [bolt]=bolt
	[printing]="cups system-config-printer simple-scan" [fish]=fish [office]=libreoffice
	[latex]=texlive
)
declare -A AUR=()

os_live_tools() {
	# the ISO's own repository (/media/…/apks) has almost nothing: a network mirror is needed
	grep -qE '^https?://' /etc/apk/repositories 2>/dev/null ||
		{ echo "No network mirror in /etc/apk/repositories. Run: setup-apkrepos -c1" >&2; exit 1; }
	# util-linux versions of the tools the installer uses (busybox lacks options, e.g. mount --mkdir)
	apk add -q dialog sfdisk btrfs-progs xfsprogs dosfstools lsblk blkid wipefs mount umount findmnt \
		util-linux-misc parted efibootmgr ||
		{ echo "apk add failed (network/mirror?)" >&2; exit 1; }
	mountpoint -q /sys/firmware/efi/efivars || mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null || true
}

os_chroot() { chroot_run "$@"; }

os_bootstrap() {
	local i
	log "apk add: ${REPO[*]}"
	mkdir -p "$MNT/etc/apk/keys" "$MNT/etc/mkinitfs"
	cp /etc/apk/keys/* "$MNT/etc/apk/keys/"
	printf '%s/%s/main\n%s/%s/community\n' "$ALPINE_MIRROR" "$ALPINE_BRANCH" "$ALPINE_MIRROR" "$ALPINE_BRANCH" >"$MNT/etc/apk/repositories"
	# written before the packages: apk keeps an existing config (new one as .apk-new), and the
	# kernel hook has to be there when the kernel package is installed
	alpine_initfs_conf
	alpine_kernel_hook
	chroot_mount   # package scripts and triggers run chrooted
	for i in 1 2; do   # one retry for slow mirrors / weak Wi-Fi
		apk --root "$MNT" --initdb -U --no-progress add "${REPO[@]}" >>"$LOG" 2>&1 && break
		((i == 2)) && die "apk add failed twice (network/mirror? see $LOG)"
		log "apk add failed, retrying once"
	done
	alpine_niri_config
}

# mkinitfs has no host-only mode, but its initramfs is built from "features" anyway: only what is
# needed to find and mount the root fs (no kms, cdrom, raid, ext4): ~20 MB instead of ~37 MB.
# Its own trigger is off, our kernel hook calls mkinitfs (fixed order: initramfs, then the copies).
alpine_initfs_conf() {
	printf '# UsrsideOS: drivers for the root fs only; the initramfs is built by /etc/kernel-hooks.d/50-usrside.hook\nfeatures="ata base keymap mmc nvme scsi usb virtio %s"\ndisable_trigger=yes\n' "$FS" \
		>"$MNT/etc/mkinitfs/mkinitfs.conf"
}

alpine_kernel_hook() {
	install -Dm755 /dev/stdin "$MNT/etc/kernel-hooks.d/50-usrside.hook" <<EOF
#!/bin/sh
# UsrsideOS: initramfs + fixed-name copies for the UEFI entry "UsrsideOS (alpine kernel)".
# Called by kernel-hooks after every kernel or module package change:
# \$1 flavor, \$2 new version (empty = kernel removed), \$3 old version
[ "\$1" = $KFLAVOR ] && [ -n "\$2" ] || exit 0
mkinitfs -o /boot/initramfs-$KFLAVOR "\$2-$KFLAVOR" || { echo "mkinitfs failed" >&2; exit 1; }
cp -f /boot/vmlinuz-$KFLAVOR /boot/vmlinuz-alpine.new && mv -f /boot/vmlinuz-alpine.new /boot/vmlinuz-alpine || exit 1
# early microcode: the uncompressed microcode cpio in front of the initramfs (one initrd= for the
# EFI stub). A microcode update alone is picked up with the next kernel update (or: apk fix linux-$KFLAVOR).
set --
for f in /boot/intel-ucode.img /boot/amd-ucode.img; do [ -f "\$f" ] && set -- "\$@" "\$f"; done
cat "\$@" /boot/initramfs-$KFLAVOR >/boot/initramfs-alpine.img.new && mv -f /boot/initramfs-alpine.img.new /boot/initramfs-alpine.img
EOF
}

# the Alpine niri package has no default-config.kdl: take the one of the installed release
alpine_niri_config() {
	local v
	[[ -x $MNT/usr/bin/niri ]] || return 0
	v=$(awk '/^P:/ { p = substr($0, 3) } /^V:/ && p == "niri" { print substr($0, 3); exit }' "$MNT/lib/apk/db/installed")
	v=${v%-r*}
	mkdir -p "$MNT/usr/share/doc/niri"
	in_target curl -fsSL -o /usr/share/doc/niri/default-config.kdl \
		"https://raw.githubusercontent.com/YaLTeR/niri/v$v/resources/default-config.kdl" ||
		{ rm -f "$MNT/usr/share/doc/niri/default-config.kdl"; log "niri $v: default config not downloaded, the installer falls back to the main branch"; }
}

os_locale() {
	# musl has no locale database: LANG only selects the translations of musl-locales
	mkdir -p "$MNT/etc/profile.d"
	printf '# UsrsideOS (before locale.sh, which only sets defaults)\nexport LANG=%s\n' "$LOCALE" >"$MNT/etc/profile.d/00-usrside-locale.sh"
	# loadkeys does not search the legacy tree of kbd-legacy: give it the file
	local km
	km=$(cd "$MNT" && find usr/share/keymaps -name "$KEYMAP.map*" 2>/dev/null | head -n1)
	sed -i "s|^keymap=.*|keymap=\"${km:+/}${km:-$KEYMAP}\"|" "$MNT/etc/conf.d/loadkeys"
	echo "$HOSTNAME_" >"$MNT/etc/hostname"
}

os_enable() { local s; for s; do in_target rc-update add "$s" default; done; }

# an apk-bootstrapped system has empty runlevels: what setup-alpine (with udev) would enable
os_services() {
	local s
	for s in devfs dmesg udev udev-trigger udev-settle; do in_target rc-update add "$s" sysinit; done
	for s in modules sysctl hostname bootmisc syslog hwclock seedrng loopback loadkeys; do in_target rc-update add "$s" boot; done
	for s in killprocs mount-ro savecache; do in_target rc-update add "$s" shutdown; done
	# iwd only handles Wi-Fi; dhcpcd only for wired interfaces, DNS via openresolv
	printf '\n# UsrsideOS: Wi-Fi is configured by iwd\nallowinterfaces en* eth*\n' >>"$MNT/etc/dhcpcd.conf"
	os_enable udev-postmount dbus elogind iwd chronyd dhcpcd
}

os_autologin() {
	sed -i "s|^tty1::.*|tty1::respawn:/sbin/agetty --autologin $USERNAME --noclear 38400 tty1 linux|" "$MNT/etc/inittab"
	grep -q '^tty1::respawn:/sbin/agetty' "$MNT/etc/inittab" || die "autologin: no tty1 line in /etc/inittab"
}

os_extra_services() {
	opt_on bluetooth && os_enable bluetooth
	opt_on printing && os_enable cupsd
	opt_on polkit && os_enable polkit
	return 0
}

# PulseAudio is the sound server; PipeWire may only come in as a dependency (portal screen sharing)
# and must not open the sound cards: wireplumber without ALSA/BlueZ monitors
wp_no_audio() {
	install -Dm644 /dev/stdin "$MNT/etc/wireplumber/wireplumber.conf.d/90-usrside-no-audio.conf" <<'EOF'
# UsrsideOS: PulseAudio owns the sound devices, PipeWire is only for screen sharing
wireplumber.profiles = {
  main = {
    monitor.alsa = disabled
    monitor.alsa-midi = disabled
    monitor.bluez = disabled
  }
}
EOF
}

# no systemd user units: PulseAudio is started with the niri session (and kept running: the default
# exit-idle-time of 20 s would end it again before the first client); without niri, clients start
# it themselves (autospawn, the default in client.conf)
os_sound() {
	[[ -z $1 ]] || echo 'spawn-at-startup "pulseaudio" "--start" "--exit-idle-time=-1"' >>"$1"
	wp_no_audio
}

os_community() { :; }

# runs the hook once more (the microcode package may have come after the kernel in the transaction)
os_kernel_hook() {
	local v uuid
	v=$(cat "$MNT/usr/share/kernel/$KFLAVOR/kernel.release" 2>/dev/null)
	[[ -n $v ]] || die "no Alpine kernel ($KFLAVOR) installed"
	in_target /etc/kernel-hooks.d/50-usrside.hook "$KFLAVOR" "${v%-"$KFLAVOR"}" "" || die "kernel hook (mkinitfs) failed"
	[[ -f $MNT/boot/vmlinuz-alpine && -f $MNT/boot/initramfs-alpine.img ]] || die "kernel/initramfs missing in /boot"
	# the Alpine initramfs mounts root with busybox mount, which knows UUID= but not PARTUUID=
	uuid=$(blkid -s UUID -o value "$ROOT")
	ROOT_CMDLINE=${ROOT_CMDLINE/root=PARTUUID=$PARTUUID/root=UUID=$uuid}
}

# with usrkrnl: pin linux-lts to the installed version in the world file. mkinitfs' own trigger is
# off already, without our hook kernel-hooks does nothing: no initramfs is built again.
os_freeze_kernel() {
	local v
	v=$(awk -v p="linux-$KFLAVOR" '/^P:/ { n = substr($0, 3) } /^V:/ && n == p { print substr($0, 3); exit }' \
		"$MNT/lib/apk/db/installed")
	[[ -n $v ]] || return 1
	sed -i "s/^linux-$KFLAVOR\$/linux-$KFLAVOR=$v/" "$MNT/etc/apk/world"
	grep -qx "linux-$KFLAVOR=$v" "$MNT/etc/apk/world" || return 1
	rm -f "$MNT/etc/kernel-hooks.d/50-usrside.hook"
}

os_hopd_service() {
	install -Dm755 "$HERE/files/hopd.openrc" "$MNT/etc/init.d/hopd"
	os_enable hopd
}

os_confirm_service() {
	install -Dm755 /dev/stdin "$MNT/etc/local.d/usrkrnl-confirm.start" <<'EOF'
#!/bin/sh
exec /usr/local/bin/usrkrnl-confirm
EOF
	os_enable local   # not enabled by default on Alpine
}

os_finish() { :; }   # resolv.conf is written by openresolv (iwd, dhcpcd) from now on
