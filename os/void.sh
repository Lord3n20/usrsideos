# UsrsideOS installer backend: Void Linux (glibc, booted from the Void live ISO).
# Sourced by ../install, see the contract there.

OS_NAME="Void Linux"
OS_KERNEL_NAME=void           # fallback entry: \vmlinuz-void + \initramfs-void.img (copied by a kernel hook)
FREE_HINT="Void package names, e.g. firefox gimp"
COMMUNITY="none needed: everything comes from the Void repositories (incl. nonfree)"
SSH_PKG=openssh
SESSION_CMD="exec dbus-run-session niri --session"
IWD_DNS=resolvconf
VOID_REPO=https://repo-default.voidlinux.org/current

BASE=(base-system linux linux-firmware dracut void-repo-nonfree btrfs-progs dosfstools sudo
	iwd openresolv dbus elogind chrony niri kitty xwayland-satellite xdg-desktop-portal-gnome
	noto-fonts-ttf chromium base-devel git efibootmgr dkms
	clang lld llvm bc flex bison pahole cpio perl openssl-devel elfutils-devel zstd curl patch xz)
UCODE_INTEL=intel-ucode
UCODE_AMD=linux-firmware-amd

EXTRAS=(
	"pipewire wireplumber" "Sound (PipeWire)" on
	"Waybar"            "Top bar (niri starts it by itself)" on
	"fuzzel"            "App launcher (Mod+D)" on
	"mako"              "Notifications" on
	"swaybg"            "Wallpaper" off
	"swayidle swaylock" "Lock screen + idle" off
	"bluez"             "Bluetooth" off
	"openssh"           "SSH" off
	"wireguard-tools"   "WireGuard" off
	"neovim"            "Editor" off
	"btop"              "Process monitor" off
	"fastfetch"         "System info with UsrsideOS logo" on
	"mpv"               "Video player" off
	"imv"               "Image viewer" off
	"zathura zathura-pdf-mupdf" "PDF viewer" off
	"Thunar"            "File manager" off
	"nerd-fonts-ttf"    "Fonts with icons (for waybar/terminal)" off
	"nvidia"            "NVIDIA driver (nonfree, DKMS)" off
	"cups"              "Printing" off
)

os_live_tools() {
	xbps-install -Syu xbps >/dev/null 2>&1 || true
	local need=()
	command -v dialog >/dev/null || need+=(dialog)
	command -v mkfs.btrfs >/dev/null || need+=(btrfs-progs)
	command -v mkfs.fat >/dev/null || need+=(dosfstools)
	((${#need[@]} == 0)) || xbps-install -Sy "${need[@]}" >/dev/null
}

os_chroot() { chroot_run "$@"; }

os_bootstrap() {
	log "xbps-install: ${REPO[*]}"
	mkdir -p "$MNT/var/db/xbps/keys"
	cp /var/db/xbps/keys/* "$MNT/var/db/xbps/keys/"
	XBPS_ARCH=x86_64 xbps-install -Sy -r "$MNT" -R "$VOID_REPO" -R "$VOID_REPO/nonfree" "${REPO[@]}" >>"$LOG" 2>&1 ||
		die "xbps-install failed"
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

os_services() { os_enable dbus elogind iwd chronyd; }

os_autologin() {
	cp -a "$MNT/etc/sv/agetty-tty1" "$MNT/etc/sv/agetty-autologin-tty1"
	sed -i "s/^GETTY_ARGS=.*/GETTY_ARGS=\"--autologin $USERNAME --noclear\"/" "$MNT/etc/sv/agetty-autologin-tty1/conf"
	rm -f "$MNT/etc/runit/runsvdir/default/agetty-tty1"
	os_enable agetty-autologin-tty1
}

# without systemd user units PipeWire is started by the session; it starts wireplumber + pulse itself
os_sound() {
	[[ -x $MNT/usr/bin/pipewire ]] || return 0
	mkdir -p "$MNT/etc/pipewire/pipewire.conf.d"
	ln -sf /usr/share/examples/wireplumber/10-wireplumber.conf "$MNT/etc/pipewire/pipewire.conf.d/"
	ln -sf /usr/share/examples/pipewire/20-pipewire-pulse.conf "$MNT/etc/pipewire/pipewire.conf.d/"
	echo 'spawn-at-startup "pipewire"' >>"$1"
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
exit 0
EOF
	local k
	k=$(chroot "$MNT" xbps-query -l | awk '{ print $2 }' | grep -E '^linux[0-9]+\.[0-9]+-' | sed 's/-[^-]*$//' | tail -n1)
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
