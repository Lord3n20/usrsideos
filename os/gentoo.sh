# UsrsideOS installer backend: Gentoo (OpenRC, booted from the Gentoo minimal ISO).
# Sourced by ../install, see the contract there.
#
# Starts from the desktop-openrc stage3 and uses the official binary packages
# (binhost) wherever possible, so only the overlay packages are compiled.

# shellcheck disable=SC2034  # contract variables of this file are used by ../install
OS_NAME="Gentoo"
OS_KERNEL_NAME=gentoo         # fallback entry: \vmlinuz-gentoo + \initramfs-gentoo.img (copied by a kernel hook)
FREE_HINT="Gentoo atoms incl. GURU, e.g. www-client/firefox-bin app-misc/foo"
COMMUNITY="GURU + pf4public overlays (eselect repository)"
SSH_PKG=net-misc/openssh
SESSION_CMD="exec dbus-run-session niri --session"
IWD_DNS=resolvconf
STAGE3_BASE=https://distfiles.gentoo.org/releases/amd64/autobuilds
STAGE3_LIST=latest-stage3-amd64-desktop-openrc.txt

# always: a bootable system with network; the rest only when chosen (see install: packages)
BASE=(sys-kernel/gentoo-kernel-bin sys-kernel/linux-firmware sys-kernel/installkernel
	sys-fs/dosfstools app-admin/sudo net-wireless/iwd net-misc/dhcpcd net-dns/openresolv
	sys-auth/elogind sys-apps/dbus net-misc/chrony dev-vcs/git sys-boot/efibootmgr)
BROWSER_NAME=ungoogled-chromium
POLKIT_SPAWN='"/usr/libexec/polkit-gnome-authentication-agent-1"'   # hyprpolkitagent needs systemd --user
BUILD_PKGS=()                         # gcc + make are part of the stage3
KERNEL_PKGS=(llvm-core/clang llvm-core/lld sys-devel/bc dev-util/pahole app-arch/cpio net-misc/curl app-arch/zstd)   # usrkrnl only
FS_PKG_btrfs=sys-fs/btrfs-progs
FS_PKG_xfs=sys-fs/xfsprogs
UCODE_INTEL=sys-firmware/intel-microcode
UCODE_AMD=""                  # AMD microcode is part of linux-firmware

# packages per option (see OPTIONS in install). Not offered on Gentoo: pacman tools, yay, games
# (Steam needs the steam-overlay), TUXEDO drivers, the PulseAudio Bluetooth module (USE flag)
declare -A PKG=(
	[desktop]="gui-wm/niri x11-terms/kitty gui-apps/xwayland-satellite sys-apps/xdg-desktop-portal-gnome gui-apps/wl-clipboard media-fonts/noto media-fonts/noto-cjk media-fonts/noto-emoji media-fonts/dejavu media-fonts/liberation-fonts"
	[waybar]=gui-apps/waybar [rofi]=x11-misc/rofi [mako]=gui-apps/mako [lock]="gui-apps/swaylock gui-apps/swayidle"
	[polkit]=gnome-extra/polkit-gnome [swaybg]=gui-apps/swaybg
	[sound]="media-sound/pulseaudio-daemon media-libs/libpulse media-sound/pulsemixer sys-firmware/sof-firmware"
	[bluetooth]=net-wireless/bluez [ssh]=net-misc/openssh [wireguard]=net-vpn/wireguard-tools
	[neovim]=app-editors/neovim [btop]=sys-process/btop [fastfetch]=app-misc/fastfetch
	[bashcomp]=app-shells/bash-completion [fzf]=app-shells/fzf [tmux]=app-misc/tmux
	[less]=sys-apps/less [unzip]=app-arch/unzip [wget]=net-misc/wget
	[mpv]=media-video/mpv [zathura]="app-text/zathura app-text/zathura-pdf-poppler" [feh]=media-gfx/feh
	[browser]=www-client/ungoogled-chromium-bin   # pf4public overlay
	[intel_media]=media-libs/libva-intel-media-driver [nvidia]=x11-drivers/nvidia-drivers [bolt]=sys-apps/bolt
	[printing]="net-print/cups app-admin/system-config-printer media-gfx/simple-scan" [fish]=app-shells/fish
	[office]=app-office/libreoffice-bin [latex]=app-text/texlive
)
declare -A AUR=()

fetch() { if command -v curl >/dev/null; then curl -fsSL -o "$2" "$1"; else wget -qO "$2" "$1"; fi; }

os_live_tools() {
	local t
	for t in dialog sfdisk mkfs.btrfs mkfs.xfs mkfs.vfat tar xz; do
		command -v "$t" >/dev/null || { echo "$t is missing on this ISO (use the Gentoo minimal or LiveGUI ISO)." >&2; exit 1; }
	done
	command -v curl >/dev/null || command -v wget >/dev/null || { echo "Neither curl nor wget found." >&2; exit 1; }
}

os_chroot() { chroot_run "$@"; }

emerge_() { in_target emerge --quiet --getbinpkg --autounmask-continue=y --autounmask-license=y "$@"; }

os_bootstrap() {
	local name tmp=$MNT/var/tmp/usrside
	log "stage3"
	mkdir -p "$tmp"
	fetch "$STAGE3_BASE/$STAGE3_LIST" "$tmp/list" || die "stage3 list could not be downloaded"
	name=$(grep -v '^#' "$tmp/list" | awk '$1 ~ /\.tar\.xz$/ { print $1; exit }')
	[[ -n $name ]] || die "no stage3 in $STAGE3_LIST"
	fetch "$STAGE3_BASE/$name" "$tmp/stage3.tar.xz" || die "stage3 download failed"
	fetch "$STAGE3_BASE/$name.sha256" "$tmp/stage3.sha256" || die "stage3 checksum download failed"
	if command -v gpg >/dev/null && [[ -r /usr/share/openpgp-keys/gentoo-release.asc ]]; then
		gpg -q --homedir "$tmp/gnupg" --import /usr/share/openpgp-keys/gentoo-release.asc 2>>"$LOG" &&
			gpg -q --homedir "$tmp/gnupg" --verify "$tmp/stage3.sha256" 2>>"$LOG" || die "stage3 signature invalid"
	fi
	(cd "$tmp" && awk -v f="${name##*/}" '$2 == f { print $1 "  stage3.tar.xz" }' stage3.sha256 | sha256sum -c --quiet) ||
		die "stage3 checksum mismatch"
	tar -xpf "$tmp/stage3.tar.xz" --xattrs-include='*.*' --numeric-owner -C "$MNT" || die "stage3 could not be unpacked"
	rm -rf "$tmp"
	chroot_mount

	log "Portage setup"
	cat >>"$MNT/etc/portage/make.conf" <<EOF

# UsrsideOS
MAKEOPTS="-j$(nproc)"
# several packages at once: most come from the binhost, then emerge mostly waits on downloads
EMERGE_DEFAULT_OPTS="\${EMERGE_DEFAULT_OPTS} --jobs=$(( $(nproc) > 4 ? 4 : $(nproc) )) --load-average=$(nproc)"
FEATURES="\${FEATURES} getbinpkg binpkg-request-signature"
USE="\${USE} dist-kernel"
ACCEPT_LICENSE="*"
EOF
	mkdir -p "$MNT/etc/portage/package.use" "$MNT/etc/portage/package.accept_keywords"
	printf 'sys-kernel/installkernel dracut\nnet-wireless/iwd standalone\n' >"$MNT/etc/portage/package.use/usrside"
	# PulseAudio as the sound server: PipeWire (portal dependency) must not provide the pulse socket
	opt_on rofi && echo "x11-misc/rofi wayland" >>"$MNT/etc/portage/package.use/usrside"
	opt_on sound && printf 'media-video/pipewire -sound-server\n*/* pulseaudio\n' >>"$MNT/etc/portage/package.use/usrside"
	printf '*/*::guru ~amd64\n*/*::pf4public ~amd64\n' >"$MNT/etc/portage/package.accept_keywords/usrside"
	# dracut needs to know the root fs without the running system
	mkdir -p "$MNT/etc/dracut.conf.d"
	# host-only: the generic initramfs is ~100 MB and lives twice on the 1 GiB ESP (with the fixed-name copy)
	printf 'hostonly="yes"\nfilesystems+=" %s "\n' "$FS" >"$MNT/etc/dracut.conf.d/usrside.conf"
	[[ $FS != btrfs ]] || echo 'add_dracutmodules+=" btrfs "' >>"$MNT/etc/dracut.conf.d/usrside.conf"
	in_target emerge-webrsync || die "emerge-webrsync failed"
	in_target getuto || die "getuto (binary package keys) failed"
	emerge_ app-eselect/eselect-repository dev-vcs/git || die "eselect-repository failed"
	in_target eselect repository enable guru pf4public || die "overlays could not be enabled"
	in_target emaint sync -r guru && in_target emaint sync -r pf4public || die "overlay sync failed"

	# the kernel hook must be there before the kernel is emerged
	os_kernel_hook
	log "emerge: ${REPO[*]}"
	emerge_ "${REPO[@]}" || die "emerge failed (see log)"
}

os_locale() {
	sed -i "s/^#\($LOCALE \)/\1/; s/^#\(en_US.UTF-8 \)/\1/" "$MNT/etc/locale.gen"
	grep -q "^$LOCALE " "$MNT/etc/locale.gen" || echo "$LOCALE ${LOCALE#*.}" >>"$MNT/etc/locale.gen"
	in_target locale-gen
	echo "LANG=\"$LOCALE\"" >"$MNT/etc/env.d/02locale"
	in_target env-update
	sed -i "s/^keymap=.*/keymap=\"$KEYMAP\"/" "$MNT/etc/conf.d/keymaps"
	echo "$HOSTNAME_" >"$MNT/etc/hostname"
	sed -i "s/^hostname=.*/hostname=\"$HOSTNAME_\"/" "$MNT/etc/conf.d/hostname"
	echo "$TIMEZONE" >"$MNT/etc/timezone"
}

os_enable() { local s; for s; do in_target rc-update add "$s" default; done; }

os_services() {
	in_target rc-update add elogind boot
	# iwd only handles Wi-Fi; dhcpcd only for wired interfaces, DNS via openresolv
	printf '\n# UsrsideOS: Wi-Fi is configured by iwd\nallowinterfaces en* eth*\n' >>"$MNT/etc/dhcpcd.conf"
	os_enable dbus iwd chronyd dhcpcd
}

os_autologin() {
	sed -i "s|^c1:.*|c1:12345:respawn:/sbin/agetty --autologin $USERNAME --noclear 38400 tty1 linux|" "$MNT/etc/inittab"
}

os_extra_services() {
	opt_on bluetooth && os_enable bluetooth
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

os_community() { :; }   # overlays are set up in os_bootstrap

# installkernel names kernels /boot/vmlinuz-VERSION; keep a fixed-name copy for the UEFI fallback entry
# Called twice: from os_bootstrap before the kernel is emerged (only installs the hook) and from
# kernel() (checks the copies, reruns installkernel if the hook did not run).
os_kernel_hook() {
	[[ -f $MNT/etc/kernel/postinst.d/95-usrside.install ]] ||
	install -Dm755 /dev/stdin "$MNT/etc/kernel/postinst.d/95-usrside.install" <<'EOF'
#!/bin/sh
# UsrsideOS: fixed-name copy of the newest kernel for the UEFI entry "UsrsideOS (gentoo kernel)"
# Arguments: $1 version, $2 installed image
d=$(dirname "$2")
cp -f "$2" "$d/vmlinuz-gentoo"
[ -f "$d/initramfs-$1.img" ] && cp -f "$d/initramfs-$1.img" "$d/initramfs-gentoo.img"
# /boot is the 1 GiB ESP and every gentoo-kernel-bin version is its own slot: keep the two newest
# versions and the running one, remove older kernel files (also their .old backups)
run=$(uname -r)
for v in $(ls "$d" | sed -n 's/^vmlinuz-//p' | grep -v -e '^gentoo$' -e '\.old$' | sort -rV | tail -n +3); do
	[ "$v" = "$run" ] && continue
	for f in vmlinuz-$v initramfs-$v.img System.map-$v config-$v; do rm -f "$d/$f" "$d/$f.old"; done
done
exit 0
EOF
	# first call: kernel not emerged yet (var/db/pkg/sys-kernel alone says nothing, the stage3 has linux-headers)
	compgen -G "$MNT/var/db/pkg/sys-kernel/gentoo-kernel-bin-*" >/dev/null || return 0
	[[ -f $MNT/boot/vmlinuz-gentoo && -f $MNT/boot/initramfs-gentoo.img ]] ||
		in_target emerge --config sys-kernel/gentoo-kernel-bin || die "emerge --config gentoo-kernel-bin failed"
	[[ -f $MNT/boot/vmlinuz-gentoo && -f $MNT/boot/initramfs-gentoo.img ]] || die "kernel/initramfs missing in /boot"
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
}

os_finish() { :; }   # resolv.conf is written by openresolv (iwd) from now on
