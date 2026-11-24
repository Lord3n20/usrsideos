# UsrsideOS installer backend: Arch Linux (booted from the Arch ISO).
# Sourced by ../install, see the contract there.

# shellcheck disable=SC2034  # contract variables of this file are used by ../install
OS_NAME="Arch Linux"
OS_KERNEL_NAME=linux          # fallback entry: \vmlinuz-linux + \initramfs-linux.img
FREE_HINT="AUR packages prefixed with aur:, e.g. aur:visual-studio-code-bin"
COMMUNITY="yay (AUR helper)"
SSH_PKG=openssh
SESSION_CMD="exec niri-session"
IWD_DNS=systemd

# always: a bootable system with network; the rest only when chosen (see install: packages)
BASE=(base linux linux-firmware dosfstools sudo iwd git efibootmgr)
BROWSER_NAME=ungoogled-chromium
LOCK_CMD=hyprlock
POLKIT_SPAWN='"systemctl" "--user" "start" "hyprpolkitagent"'
BUILD_PKGS=(base-devel)               # compiler + make: hopd, usrkrnl, yay
KERNEL_PKGS=(dkms clang lld llvm bc pahole cpio perl openssl zstd curl)   # usrkrnl only
FS_PKG_btrfs=btrfs-progs
FS_PKG_xfs=xfsprogs
UCODE_INTEL=intel-ucode
UCODE_AMD=amd-ucode

# packages per option (see OPTIONS in install); AUR = built with yay
declare -A PKG=(
	[desktop]="niri kitty xwayland-satellite xdg-desktop-portal-gnome wl-clipboard noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-dejavu ttf-liberation"
	[waybar]=waybar [rofi]=rofi [mako]=mako [lock]="hyprlock swayidle" [polkit]=hyprpolkitagent [swaybg]=swaybg
	[sound]="pulseaudio pulseaudio-alsa pulsemixer sof-firmware" [sound_bt]=pulseaudio-bluetooth
	[bluetooth]="bluez bluez-utils" [ssh]=openssh [wireguard]=wireguard-tools
	[neovim]=neovim [btop]=btop [fastfetch]=fastfetch [bashcomp]=bash-completion [fzf]=fzf [tmux]=tmux
	[less]=less [unzip]=unzip [wget]=wget [pkgtools]=pacman-contrib
	[mpv]=mpv [zathura]="zathura zathura-pdf-poppler" [feh]=feh
	[yay]=base-devel
	[intel_media]=intel-media-driver [nvidia]="linux-headers nvidia-open-dkms nvidia-utils nvidia-prime"
	[bolt]=bolt [tuxedo]=linux-headers
	[printing]="cups system-config-printer simple-scan" [fish]=fish [office]=libreoffice-fresh
	[games]="steam mangohud"   # multilib, enabled in os_bootstrap
	[latex]="texlive-basic texlive-latex texlive-latexrecommended texlive-fontsrecommended"
)
declare -A AUR=( [browser]=ungoogled-chromium-bin [tuxedo]=tuxedo-drivers-dkms )

os_live_tools() {
	command -v dialog >/dev/null || pacman -Sy --noconfirm dialog >/dev/null
	command -v arch-chroot >/dev/null || pacman -Sy --noconfirm arch-install-scripts >/dev/null
	command -v mkfs.xfs >/dev/null || pacman -Sy --noconfirm xfsprogs >/dev/null
}

os_chroot() { arch-chroot "$MNT" "$@"; }

# Steam needs the multilib repository, on the ISO (for pacstrap) and in the new system
multilib_on() {
	grep -q '^\[multilib\]' "$1" || printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >>"$1"
}

os_bootstrap() {
	log "pacstrap: ${REPO[*]}"
	if opt_on games; then multilib_on /etc/pacman.conf; pacman -Sy >>"$LOG" 2>&1 || true; fi
	# slow mirrors / weak Wi-Fi: refresh the mirror list once and retry (downloaded packages stay
	# in the target cache, so the second run only fetches what is missing)
	# tests: an extra read-only cache; pacman downloads into the first writable --cachedir
	local cache=()
	[[ -n $TEST_CACHEDIR ]] && cache=(--cachedir="$MNT/var/cache/pacman/pkg" --cachedir="$TEST_CACHEDIR")
	# before pacstrap: mkinitcpio (sd-vconsole) runs during it and puts the keymap into the initramfs
	install -Dm644 /dev/stdin "$MNT/etc/vconsole.conf" <<<"KEYMAP=$KEYMAP"
	if ! pacstrap -K "$MNT" "${REPO[@]}" "${cache[@]}" >>"$LOG" 2>&1; then
		log "pacstrap failed, refreshing mirrors and retrying once"
		if command -v reflector >/dev/null; then
			reflector --protocol https --latest 20 --sort rate --download-timeout 5 \
				--save /etc/pacman.d/mirrorlist >>"$LOG" 2>&1 || log "reflector failed, keeping the mirror list"
		fi
		pacman -Syy >>"$LOG" 2>&1 || true
		pacstrap -K "$MNT" "${REPO[@]}" "${cache[@]}" >>"$LOG" 2>&1 || die "pacstrap failed twice (network/mirrors? see $LOG)"
	fi
	if opt_on games; then multilib_on "$MNT/etc/pacman.conf"; fi
}

os_locale() {
	sed -i "s/^#\($LOCALE \)/\1/; s/^#\(en_US.UTF-8 \)/\1/" "$MNT/etc/locale.gen"
	in_target locale-gen
	echo "LANG=$LOCALE" >"$MNT/etc/locale.conf"
	echo "KEYMAP=$KEYMAP" >"$MNT/etc/vconsole.conf"
	# udev starts systemd-vconsole-setup again when the GPU driver appears; by then niri may hold
	# tty1 in graphics mode and loadkeys fails with EIO. The keymap is already set (initramfs, or
	# the first run before getty with usrkrnl), so that late failure must not mark the unit failed.
	install -Dm644 /dev/stdin "$MNT/etc/systemd/system/systemd-vconsole-setup.service.d/10-usrside.conf" <<'EOF2'
[Service]
ExecStart=
ExecStart=-/usr/lib/systemd/systemd-vconsole-setup
EOF2
	echo "$HOSTNAME_" >"$MNT/etc/hostname"
}

os_enable() { in_target systemctl enable "$@"; }

# iwd only handles Wi-Fi; wired interfaces get DHCP from systemd-networkd (DNS via resolved)
os_services() {
	install -Dm644 /dev/stdin "$MNT/etc/systemd/network/20-wired.network" <<'EOF'
[Match]
Name=en* eth*

[Network]
DHCP=yes
EOF
	os_enable iwd systemd-networkd systemd-resolved systemd-timesyncd
}

os_autologin() {
	mkdir -p "$MNT/etc/systemd/system/getty@tty1.service.d"
	printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin %s --noclear %%I $TERM\n' "$USERNAME" \
		>"$MNT/etc/systemd/system/getty@tty1.service.d/autologin.conf"
}

os_extra_services() {
	opt_on bluetooth && os_enable bluetooth
	opt_on printing && os_enable cups.socket
	opt_on pkgtools && os_enable paccache.timer
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

# PulseAudio through its systemd user socket: starts on the first sound client, for every user
os_sound() {
	in_target systemctl --global enable pulseaudio.socket
	wp_no_audio
}

os_community() {
	opt_on yay || return 0
	log "yay + AUR packages"
	as_user 'cd /tmp && rm -rf yay-bin && git clone -q https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si --noconfirm' ||
		die "yay could not be built"
	local aur=() k
	for k in "${!AUR[@]}"; do
		# shellcheck disable=SC2206  # a list of package names
		opt_on "$k" && aur+=(${AUR[$k]})
	done
	aur+=("${EXTRA_AUR[@]}")
	((${#aur[@]})) || return 0
	as_user "yay -S --noconfirm --needed --removemake ${aur[*]}" || die "AUR packages failed (${aur[*]})"
}

os_kernel_hook() { :; }   # pacman installs /boot/vmlinuz-linux under a fixed name already

os_hopd_service() {
	install -Dm644 "$HERE/files/hopd.service" "$MNT/etc/systemd/system/hopd.service"
	os_enable hopd
}

os_confirm_service() {
	install -Dm644 "$HERE/files/usrkrnl-confirm.service" "$MNT/etc/systemd/system/usrkrnl-confirm.service"
	os_enable usrkrnl-confirm
}

os_finish() {
	ln -sf ../run/systemd/resolve/stub-resolv.conf "$MNT/etc/resolv.conf"   # only now: the chroot needed the ISO's DNS
}
