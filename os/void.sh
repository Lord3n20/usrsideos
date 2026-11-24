# UsrsideOS installer backend: Void Linux (glibc, booted from the Void live ISO).
# Sourced by ../install, see the contract there.

# shellcheck disable=SC2034  # contract variables of this file are used by ../install
OS_NAME="Void Linux"
OS_KERNEL_NAME=void           # fallback entry: \vmlinuz-void + \initramfs-void.img (copied by a kernel hook)
FREE_HINT="Void package names, e.g. firefox gimp"
COMMUNITY="none needed: everything comes from the Void repositories (incl. nonfree)"
SSH_PKG=openssh
SESSION_CMD="exec dbus-run-session niri --session"
IWD_DNS=resolvconf
VOID_REPO=https://repo-default.voidlinux.org/current

# always: a bootable system with network; the rest only when chosen (see install: packages)
BASE=(base-system linux linux-firmware dracut void-repo-nonfree dosfstools sudo
	iwd openresolv dbus elogind chrony git efibootmgr)
BROWSER_NAME=chromium
LOCK_CMD=swaylock                     # hyprlock is not packaged for Void
POLKIT_SPAWN='"/usr/libexec/polkit-gnome-authentication-agent-1"'   # hyprpolkitagent: not packaged
BUILD_PKGS=(base-devel)               # compiler + make: hopd, usrkrnl
KERNEL_PKGS=(dkms clang lld llvm bc flex bison pahole cpio perl openssl-devel elfutils-devel zstd curl patch xz)   # usrkrnl only
FS_PKG_btrfs=btrfs-progs
FS_PKG_xfs=xfsprogs
UCODE_INTEL=intel-ucode
UCODE_AMD=linux-firmware-amd

# packages per option (see OPTIONS in install). Not offered on Void: pacman tools, yay, games
# (Steam needs the multilib repositories), the PulseAudio Bluetooth module (part of pulseaudio)
declare -A PKG=(
	[desktop]="niri kitty xwayland-satellite xdg-desktop-portal-gnome wl-clipboard noto-fonts-ttf noto-fonts-cjk noto-fonts-emoji dejavu-fonts-ttf liberation-fonts-ttf"
	[waybar]=Waybar [rofi]=rofi [mako]=mako [lock]="swaylock swayidle" [polkit]=polkit-gnome [swaybg]=swaybg
	[sound]="pulseaudio alsa-plugins-pulseaudio pulsemixer sof-firmware"
	[bluetooth]=bluez [ssh]=openssh [wireguard]=wireguard-tools
	[neovim]=neovim [btop]=btop [fastfetch]=fastfetch [bashcomp]=bash-completion [fzf]=fzf [tmux]=tmux
	[less]=less [unzip]=unzip [wget]=wget
	[mpv]=mpv [zathura]="zathura zathura-pdf-poppler" [feh]=feh
	[browser]=chromium
	[intel_media]=intel-media-driver [nvidia]=nvidia [bolt]=bolt [tuxedo]=tuxedo-drivers
	[printing]="cups system-config-printer simple-scan" [fish]=fish-shell [office]=libreoffice
	[latex]=texlive-basic
)
declare -A AUR=()

os_live_tools() {
	# an older live ISO refuses every transaction until xbps itself is updated
	log "live ISO: updating xbps"
	xbps-install -Syu xbps >>"$LOG" 2>&1 || true   # rc is not reliable for "already up to date"
	xbps-install -un xbps 2>/dev/null | grep -q '^xbps-' && die "could not update xbps on the live ISO (network? see $LOG)"
	local need=()
	command -v dialog >/dev/null || need+=(dialog)
	command -v mkfs.btrfs >/dev/null || need+=(btrfs-progs)
	command -v mkfs.xfs >/dev/null || need+=(xfsprogs)
	command -v mkfs.fat >/dev/null || need+=(dosfstools)
	((${#need[@]} == 0)) || xbps-install -Sy "${need[@]}" >/dev/null
}

os_chroot() { chroot_run "$@"; }

os_bootstrap() {
	log "xbps-install: ${REPO[*]}"
	mkdir -p "$MNT/var/db/xbps/keys"
	cp /var/db/xbps/keys/* "$MNT/var/db/xbps/keys/"
	local i
	for i in 1 2; do   # one retry for slow mirrors / weak Wi-Fi; finished downloads stay in the cache
		XBPS_ARCH=x86_64 xbps-install -Sy -r "$MNT" -R "$VOID_REPO" -R "$VOID_REPO/nonfree" "${REPO[@]}" >>"$LOG" 2>&1 && break
		((i == 2)) && die "xbps-install failed twice (network/mirror? see $LOG)"
		log "xbps-install failed, retrying once"
	done
	chroot_mount
}

os_locale() {
	sed -i "s/^#\($LOCALE \)/\1/; s/^#\(en_US.UTF-8 \)/\1/" "$MNT/etc/default/libc-locales"
	in_target xbps-reconfigure -f glibc-locales
	echo "LANG=$LOCALE" >"$MNT/etc/locale.conf"
	if grep -q '^#\?KEYMAP=' "$MNT/etc/rc.conf"; then
		sed -i "s/^#\?KEYMAP=.*/KEYMAP=\"$KEYMAP\"/" "$MNT/etc/rc.conf"
	else
		echo "KEYMAP=\"$KEYMAP\"" >>"$MNT/etc/rc.conf"
	fi
	echo "$HOSTNAME_" >"$MNT/etc/hostname"
}

# runit: a service is enabled by a link in the default runlevel
os_enable() { local s; for s; do ln -sfn "/etc/sv/$s" "$MNT/etc/runit/runsvdir/default/$s"; done; }

# iwd only handles Wi-Fi; dhcpcd (part of base-system) only for wired interfaces, DNS via openresolv
os_services() {
	printf '\n# UsrsideOS: Wi-Fi is configured by iwd\nallowinterfaces en* eth*\n' >>"$MNT/etc/dhcpcd.conf"
	os_enable dbus elogind iwd chronyd dhcpcd
}

os_autologin() {
	# new service dir (agetty-generic/run takes the tty from the dir name); the stock conf sets
	# GETTY_ARGS indented inside an if, so write our own instead of editing it
	local d=$MNT/etc/sv/agetty-autologin-tty1
	mkdir -p "$d"
	ln -sfn ../agetty-generic/run "$d/run"
	ln -sfn ../agetty-generic/finish "$d/finish"
	ln -sfn /run/runit/supervise.agetty-autologin-tty1 "$d/supervise"
	printf 'GETTY_ARGS="--autologin %s --noclear"\nBAUD_RATE=38400\nTERM_NAME=linux\n' "$USERNAME" >"$d/conf"
	rm -f "$MNT/etc/runit/runsvdir/default/agetty-tty1"
	os_enable agetty-autologin-tty1
}

os_extra_services() {
	opt_on bluetooth && os_enable bluetoothd
	opt_on printing && os_enable cupsd
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

# no systemd user units: PulseAudio is started with the niri session; without niri, clients start
# it themselves (autospawn, the default in client.conf)
os_sound() {
	[[ -z $1 ]] || echo 'spawn-at-startup "pulseaudio" "--start"' >>"$1"
	wp_no_audio
}

os_community() { :; }

# Void names kernels /boot/vmlinuz-VERSION; keep a fixed-name copy for the UEFI fallback entry
os_kernel_hook() {
	install -Dm755 /dev/stdin "$MNT/etc/kernel.d/post-install/60-usrside" <<'EOF'
#!/bin/sh
# UsrsideOS: fixed-name copy of the newest kernel for the UEFI entry "UsrsideOS (void kernel)"
# Arguments: $1 package name, $2 version
[ -f "/boot/vmlinuz-$2" ] || exit 0
cp -f "/boot/vmlinuz-$2" /boot/vmlinuz-void
[ -f "/boot/initramfs-$2.img" ] && cp -f "/boot/initramfs-$2.img" /boot/initramfs-void.img
# /boot is the 1 GiB ESP and Void keeps replaced kernels (preserve): drop the ones no package owns
# any more (vkpurge list). Only versions older than the one just installed, never our copy
# ("void") and never the running kernel: vkpurge reads the owners from the pkgdb, which need not
# list the new package yet while its own hooks run, and in the installer chroot uname is the ISO's.
run=$(uname -r)
if command -v vkpurge >/dev/null; then
	for k in $(vkpurge list all 2>/dev/null); do
		[ "$k" = void ] || [ "$k" = "$2" ] || [ "$k" = "$run" ] && continue
		[ "$(printf '%s\n%s\n' "$k" "$2" | sort -V | head -n1)" = "$k" ] || continue
		vkpurge rm "$k" >/dev/null 2>&1 || true
	done
fi
exit 0
EOF
	# host-only initramfs like void-installer: the generic one is ~140 MB, twice on the ESP with the copy
	mkdir -p "$MNT/etc/dracut.conf.d"
	printf 'hostonly="yes"\nfilesystems+=" %s "\n' "$FS" >"$MNT/etc/dracut.conf.d/10-usrside.conf"
	local k
	# the series package (linux6.18) is a dependency of the "linux" meta package; listing all
	# installed linux* packages would also find linux6.18-headers (pulled in by dkms)
	k=$(chroot "$MNT" xbps-query -x linux | sed -nE 's/^(linux[0-9]+\.[0-9]+)[<>=].*/\1/p' | head -n1)
	[[ -n $k ]] || die "no Void kernel package found"
	in_target xbps-reconfigure -f "$k" || die "xbps-reconfigure $k failed"
	[[ -f $MNT/boot/vmlinuz-void && -f $MNT/boot/initramfs-void.img ]] || die "kernel/initramfs missing in /boot"
}

os_hopd_service() {
	install -Dm755 "$HERE/files/hopd.run" "$MNT/etc/sv/hopd/run"
	os_enable hopd
}

os_confirm_service() {
	[[ -f $MNT/etc/rc.local ]] || printf '#!/bin/sh\n' >"$MNT/etc/rc.local"
	echo '/usr/local/bin/usrkrnl-confirm' >>"$MNT/etc/rc.local"
}

os_finish() { :; }   # resolv.conf is written by openresolv (iwd) from now on
