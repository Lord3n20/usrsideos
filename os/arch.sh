# UsrsideOS installer backend: Arch Linux (booted from the Arch ISO).
# Sourced by ../install, see the contract there.

OS_NAME="Arch Linux"
OS_KERNEL_NAME=linux          # fallback entry: \vmlinuz-linux + \initramfs-linux.img
FREE_HINT="AUR packages prefixed with aur:, e.g. aur:visual-studio-code-bin"
COMMUNITY="yay (AUR helper)"
SSH_PKG=openssh
SESSION_CMD="exec niri-session"
IWD_DNS=systemd

BASE=(base linux linux-firmware btrfs-progs dosfstools sudo iwd niri kitty xwayland-satellite
	xdg-desktop-portal-gnome noto-fonts base-devel git efibootmgr
	dkms clang lld llvm bc pahole cpio perl openssl zstd curl)
UCODE_INTEL=intel-ucode
UCODE_AMD=amd-ucode
AUR_BASE=(ungoogled-chromium-bin)

EXTRAS=(
	"pipewire pipewire-pulse wireplumber" "Sound (PipeWire)" on
	"waybar"            "Top bar (niri starts it by itself)" on
	"fuzzel"            "App launcher (Mod+D)" on
	"mako"              "Notifications" on
	"swaybg"            "Wallpaper" off
	"swayidle hyprlock" "Lock screen + idle" off
	"bluez bluez-utils" "Bluetooth" off
	"openssh"           "SSH" off
	"wireguard-tools"   "WireGuard" off
	"neovim"            "Editor" off
	"btop"              "Process monitor" off
	"fastfetch"         "System info with UsrsideOS logo" on
	"mpv"               "Video player" off
	"imv"               "Image viewer" off
	"zathura zathura-pdf-mupdf" "PDF viewer" off
	"thunar"            "File manager" off
	"ttf-jetbrains-mono-nerd" "Font with icons (for waybar/terminal)" off
	"nvidia-open-dkms nvidia-utils" "NVIDIA driver" off
	"cups"              "Printing" off
)

os_live_tools() {
	command -v dialog >/dev/null || pacman -Sy --noconfirm dialog >/dev/null
	command -v arch-chroot >/dev/null || pacman -Sy --noconfirm arch-install-scripts >/dev/null
}

os_chroot() { arch-chroot "$MNT" "$@"; }

os_bootstrap() {
	log "pacstrap: ${REPO[*]}"
	pacstrap -K "$MNT" "${REPO[@]}" >>"$LOG" 2>&1 || die "pacstrap failed"
}

os_locale() {
	sed -i "s/^#\($LOCALE \)/\1/; s/^#\(en_US.UTF-8 \)/\1/" "$MNT/etc/locale.gen"
	in_target locale-gen
	echo "LANG=$LOCALE" >"$MNT/etc/locale.conf"
	echo "KEYMAP=$KEYMAP" >"$MNT/etc/vconsole.conf"
	echo "$HOSTNAME_" >"$MNT/etc/hostname"
}

os_enable() { in_target systemctl enable "$@"; }

os_services() { os_enable iwd systemd-resolved systemd-timesyncd; }

os_autologin() {
	mkdir -p "$MNT/etc/systemd/system/getty@tty1.service.d"
	printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin %s --noclear %%I $TERM\n' "$USERNAME" \
		>"$MNT/etc/systemd/system/getty@tty1.service.d/autologin.conf"
}

os_sound() { :; }   # PipeWire is started by systemd user units

os_community() {
	log "yay + AUR packages"
	as_user 'cd /tmp && rm -rf yay-bin && git clone -q https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si --noconfirm' ||
		die "yay could not be built"
	as_user "yay -S --noconfirm --needed --removemake ${AUR_BASE[*]} ${EXTRA_AUR[*]}" ||
		die "AUR packages failed (${AUR_BASE[*]} ${EXTRA_AUR[*]})"
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
