# UsrsideOS installer backend: the pure UsrsideOS (booted from the UsrsideOS live system).
# Sourced by ../install, see the contract there.
#
# Binary packages from Arch (core/extra/multilib) + the own repository [usrside] (rcyay, usrside-*, runit, s6),
# installed with rcyay --root instead of pacstrap, like bootstrap/glibc-rootfs of rcyay. Everything comes
# from the live system itself: rcyay, pacman, the repository in /srv/usrside and the running kernel (no Arch ISO).
# Settings (menu entry "Init/libc" or answers file):
#   INIT=systemd|busybox|runit|s6   PID 1 (default runit); the services of all four are installed, the kernel
#                                   gets init=PATH from /usr/share/usrside/inits, Init = in /etc/rcyay.conf
#   LIBC=glibc|musl                 musl: interface only, until the musl variant exists (rcyay M3)
#   PROFIL=standard|minimal         userland: standard keeps the GNU tools, minimal = BusyBox instead of GNU
#                                   coreutils/findutils/grep/sed/gawk/diffutils (VirtualProvides; makepkg may fail)
# No Flatpak/Snap: everything native through rcyay (repos + AUR).

# shellcheck disable=SC2034  # contract variables of this file are used by ../install
OS_NAME="UsrsideOS"
OS_LIKE=arch                  # ID_LIKE: usrkrnl/setup and scripts treat it like Arch (pacman)
OS_AUR=1                      # AUR packages through rcyay
OS_KERNEL_NAME=live           # fallback entry: the kernel of the live system, \vmlinuz-live
OS_INITRAMFS=0                # … which has the root filesystem built in (usrkrnl), no initramfs
FREE_HINT="AUR packages prefixed with aur:, e.g. aur:visual-studio-code-bin"
COMMUNITY="AUR packages through rcyay"
SSH_PKG=openssh
SESSION_CMD="exec niri-session"   # set per init in os_prepare
IWD_DNS=resolvconf
USRSIDE_REPO=/srv/usrside     # repository [usrside] of the live system (file:// server)
USRSIDE_INITS=/usr/share/usrside/inits

INIT=runit
LIBC=glibc
PROFIL=standard

# always: a bootable system with network; the rest only when chosen (see install: packages).
# systemd stays installed with every init (pacman, udev, sysusers/tmpfiles hooks need it, see rcyay
# doc/usrside-glibc.md); dbus + seatd replace logind/socket activation under busybox/runit/s6.
BASE=(usrside-base usrside-udev usrside-dienste systemd dbus seatd runit s6 s6-linux-init
	openssh dhcpcd openresolv iwd chrony kbd base-devel wget linux-firmware dosfstools sudo git efibootmgr)
BROWSER_NAME=ungoogled-chromium
POLKIT_SPAWN='"systemctl" "--user" "start" "hyprpolkitagent"'   # set per init in os_prepare
BUILD_PKGS=(base-devel)
KERNEL_PKGS=(dkms clang lld llvm bc cpio perl python openssl zstd curl)
FS_PKG_btrfs=btrfs-progs
FS_PKG_xfs=xfsprogs
UCODE_INTEL=intel-ucode
UCODE_AMD=amd-ucode

# packages per option (see OPTIONS in install); AUR = built with rcyay. No linux-headers: there is no
# distribution kernel, the DKMS modules (NVIDIA, TUXEDO) are built against usrkrnl by usrkrnl/setup.
declare -A PKG=(
	[desktop]="niri kitty xwayland-satellite xdg-desktop-portal-gnome wl-clipboard noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-dejavu ttf-liberation"
	[waybar]=waybar [rofi]=rofi [mako]=mako [lock]="swaylock swayidle" [polkit]=hyprpolkitagent [swaybg]=swaybg
	[sound]="pulseaudio pulseaudio-alsa pulsemixer sof-firmware" [sound_bt]=pulseaudio-bluetooth
	[bluetooth]="bluez bluez-utils" [ssh]=openssh [wireguard]=wireguard-tools
	[neovim]=neovim [btop]=btop [fastfetch]=fastfetch [bashcomp]=bash-completion [fzf]=fzf [tmux]=tmux
	[less]=less [unzip]=unzip [wget]=wget [pkgtools]=pacman-contrib
	[mpv]=mpv [zathura]="zathura zathura-pdf-poppler" [feh]=feh
	[yay]=base-devel   # the AUR helper is rcyay itself; the option only switches AUR builds on
	[intel_media]=intel-media-driver [nvidia]="nvidia-open-dkms nvidia-utils nvidia-prime"
	[bolt]=bolt [tuxedo]=dkms
	[printing]="cups system-config-printer simple-scan" [fish]=fish [office]=libreoffice-fresh
	[games]="steam mangohud"   # multilib is always on in /etc/pacman.conf
	[latex]="texlive-basic texlive-latex texlive-latexrecommended texlive-fontsrecommended"
)
declare -A AUR=( [browser]=ungoogled-chromium-bin [tuxedo]=tuxedo-drivers-dkms )

usrside_init_path() { awk -v i="$1" '$1 == i { print $2; exit }' "$USRSIDE_INITS" 2>/dev/null; }

# prints what is wrong with INIT/LIBC/PROFIL (empty = fine)
usrside_problem() {
	case $INIT in systemd|busybox|runit|s6) ;; *) echo "INIT=$INIT: systemd, busybox, runit or s6"; return ;; esac
	case $LIBC in
		glibc) ;;
		musl) echo "LIBC=musl: the musl variant of UsrsideOS is not available yet (rcyay M3), use glibc"; return ;;
		*) echo "LIBC=$LIBC: glibc or musl"; return ;;
	esac
	case $PROFIL in standard|minimal) ;; *) echo "PROFIL=$PROFIL: standard or minimal"; return ;; esac
	[[ -n $(usrside_init_path "$INIT") ]] || echo "INIT=$INIT: no init path in $USRSIDE_INITS of the live system"
}

os_answers() {
	local p; p=$(usrside_problem)
	[[ -z $p ]] && return 0
	log "--answers: $p"; echo "--answers: $p" >&2; return 1
}

os_menu_label() { echo "Init/libc:        $INIT, $LIBC, $PROFIL"; }
os_menu() {
	local v
	v=$(dlg --title "Init" --default-item "$INIT" --menu "PID 1 of the new system. The services of all four are installed; switch later with: rcyay --init NAME (+ init= in the boot entry)." 14 78 4 \
		runit "runit (default): small, supervised services" \
		s6 "s6 + s6-linux-init" \
		busybox "BusyBox init (/etc/inittab)" \
		systemd "systemd (like Arch)") && INIT=$v
	v=$(dlg --title "Userland" --default-item "$PROFIL" --menu "BusyBox always fills the free paths (which, init, getty …)." 12 78 2 \
		standard "GNU coreutils, grep, sed … stay (reliable for makepkg/AUR)" \
		minimal "BusyBox instead of the GNU tools (some package scripts may fail)") && PROFIL=$v
	v=$(dlg --title "libc" --default-item "$LIBC" --menu "C library" 10 78 2 \
		glibc "glibc (Arch binary packages, NVIDIA, Steam)" \
		musl "musl (not available yet)") && LIBC=$v
	local p; p=$(usrside_problem)
	[[ -z $p ]] || { dlg --msgbox "$p" 8 70; LIBC=glibc; }
	return 0
}

# once before the installation: everything that depends on INIT and the selection
os_prepare() {
	local p ip
	p=$(usrside_problem)
	[[ -z $p ]] || { echo "$p" >&2; return 1; }
	if [[ $INIT == systemd ]]; then
		SESSION_CMD="exec niri-session"
		POLKIT_SPAWN='"systemctl" "--user" "start" "hyprpolkitagent"'
	else
		# no logind: libseat talks to seatd, a session bus from dbus-run-session
		SESSION_CMD="export LIBSEAT_BACKEND=seatd; exec dbus-run-session niri --session"
		PKG[polkit]=polkit-gnome   # hyprpolkitagent needs systemd --user
		POLKIT_SPAWN='"/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1"'
	fi
	# the live kernel has no headers: DKMS modules only work with usrkrnl
	if { opt_on nvidia || opt_on tuxedo; } && ! ((USRKRNL)); then
		USRKRNL=1
		log "NVIDIA/TUXEDO drivers selected: usrkrnl switched on (DKMS modules are built against usrkrnl)"
	fi
	ip=$(usrside_init_path "$INIT")
	[[ " $KERNEL_ARGS " == *" init="* ]] || KERNEL_ARGS+=" init=$ip"
	log "UsrsideOS: init $INIT ($ip), libc $LIBC, userland $PROFIL"
	return 0
}

os_live_tools() {
	local need=() c
	for c in dialog:dialog mkfs.fat:dosfstools mkfs.btrfs:btrfs-progs mkfs.xfs:xfsprogs efibootmgr:efibootmgr; do
		command -v "${c%%:*}" >/dev/null || need+=("${c#*:}")
	done
	if [[ ! -s /etc/pacman.d/gnupg/pubring.gpg && ! -s /etc/pacman.d/gnupg/pubring.kbx ]]; then
		pacman-key --init >/dev/null 2>&1; pacman-key --populate archlinux >/dev/null 2>&1
	fi
	local i out
	for ((i = 1; ${#need[@]} && i <= 3; i++)); do   # right after booting the network may still come up
		# rcyay, not pacman: it overwrites the BusyBox links in free paths (mkfs.vfat …)
		out=$(rcyay -Sy --repo --noconfirm --needed "${need[@]}" 2>&1) && break
		((i == 3)) && { echo "$out" | tail -n 5 >&2; echo "Could not install ${need[*]} into the live system (network? pacman -Sy ${need[*]})" >&2; exit 1; }
		sleep 5
	done
	[[ -d $USRSIDE_REPO ]] || { echo "The live system has no repository $USRSIDE_REPO" >&2; exit 1; }
	mountpoint -q /sys/firmware/efi/efivars || mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null || true
}

os_chroot() { chroot_run "$@"; }

usrside_pacman_conf() {   # $1 = server of [usrside]
	cat <<EOF
# /etc/pacman.conf – UsrsideOS (installer, like bootstrap/glibc-rootfs)
[options]
HoldPkg     = pacman glibc rcyay usrside-base
Architecture = x86_64
CheckSpace
ParallelDownloads = 5
DownloadUser = alpm
SigLevel    = Required DatabaseOptional
LocalFileSigLevel = Optional

# own repository (rcyay, usrside-*, runit, s6); unsigned, lives in the system itself
[usrside]
SigLevel = Optional TrustAll
Server = $1

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

# Steam and the lib32 packages
[multilib]
Include = /etc/pacman.d/mirrorlist
EOF
}

usrside_conf_set() {   # KEY VALUE FILE (rcyay.conf, [options])
	if grep -q "^#\?$1 *=" "$3"; then sed -i "0,/^#\?$1 *=.*/s||$1 = $2|" "$3"; else printf '%s = %s\n' "$1" "$2" >>"$3"; fi
}

# rcyay for the target, with its own rcyay.conf (Init, VirtualProvides)
rc_target() { rcyay --root "$MNT" --config "$MNT/etc/pacman.conf" --rcyayconf "$MNT/etc/rcyay.conf" --noconfirm "$@"; }

os_bootstrap() {
	local w=/tmp/usrside-install vprov="which" i pkg
	[[ $PROFIL == minimal ]] && vprov="which coreutils findutils grep sed gawk awk diffutils"
	log "rcyay --root: ${REPO[*]} (init $INIT, userland $PROFIL)"
	rm -rf "$w"; mkdir -p "$w"
	usrside_pacman_conf "file://$USRSIDE_REPO" >"$w/pacman.conf"
	mkdir -p "$MNT"/{etc,var/lib/pacman,var/cache/pacman/pkg,srv,tmp}
	chmod 1777 "$MNT/tmp"
	# /dev /proc /sys /run for the package hooks (sysusers, tmpfiles, rcyay-dienste); resolv.conf belongs
	# to the filesystem package, the copy of the live system only comes afterwards
	chroot_mount
	rm -f "$MNT/etc/resolv.conf"
	# rcyay.conf of usrside-init (it comes with the package, so a copy for the installation)
	pkg=$(ls "$USRSIDE_REPO"/usrside-init-[0-9]*.pkg.tar.zst 2>/dev/null | tail -n1)
	[[ -n $pkg ]] || die "usrside-init missing in $USRSIDE_REPO"
	bsdtar -xOf "$pkg" etc/rcyay.conf >"$w/rcyay.conf" || die "no etc/rcyay.conf in $pkg"
	usrside_conf_set VirtualProvides "$vprov" "$w/rcyay.conf"
	usrside_conf_set Init "$INIT" "$w/rcyay.conf"
	local P=(pacman --config "$w/pacman.conf" -r "$MNT" --cachedir "$MNT/var/cache/pacman/pkg" --noconfirm)
	local RC=(rcyay --config "$w/pacman.conf" --root "$MNT" --rcyayconf "$w/rcyay.conf" --noconfirm)
	"${P[@]}" -Sy >>"$LOG" 2>&1 || die "pacman -Sy failed (network/mirrors? see $LOG)"
	if [[ $PROFIL == minimal ]]; then
		# usrside-provides first, so that pacman does not pull in the GNU tools at all
		"${P[@]}" -S --needed filesystem >>"$LOG" 2>&1 || die "filesystem could not be installed"
		"${RC[@]}" --provides apply >>"$LOG" 2>&1 || die "rcyay --provides apply failed"
	fi
	for i in 1 2; do   # one retry for slow mirrors / weak Wi-Fi; finished downloads stay in the cache
		"${RC[@]}" --repo --cachedir "$MNT/var/cache/pacman/pkg" -S --needed "${REPO[@]}" >>"$LOG" 2>&1 && break
		((i == 2)) && die "rcyay -S failed twice (network/mirrors? see $LOG)"
		log "rcyay -S failed, refreshing the databases and retrying once"
		"${P[@]}" -Syy >>"$LOG" 2>&1 || true
	done
	"${RC[@]}" --provides apply >>"$LOG" 2>&1 || die "rcyay --provides apply failed"
	cp -L /etc/resolv.conf "$MNT/etc/resolv.conf"

	# the new system: same repositories, [usrside] as a local copy, own keyring, Init
	usrside_pacman_conf "file://$USRSIDE_REPO" >"$MNT/etc/pacman.conf"
	grep -q '^Server' /etc/pacman.d/mirrorlist 2>/dev/null && cp /etc/pacman.d/mirrorlist "$MNT/etc/pacman.d/mirrorlist"
	rm -rf "$MNT$USRSIDE_REPO"; cp -a "$USRSIDE_REPO" "$MNT$USRSIDE_REPO"
	cp "$w/rcyay.conf" "$MNT/etc/rcyay.conf"
	in_target pacman-key --init || die "pacman-key --init failed"
	in_target pacman-key --populate archlinux || die "pacman-key --populate failed"
	in_target gpgconf --homedir /etc/pacman.d/gnupg --kill all || true
	rm -f "$MNT"/etc/pacman.d/gnupg/S.*
	# services of all installed units for the chosen init (systemd: nothing generated)
	rc_target --init "$INIT" >>"$LOG" 2>&1 || warn "rcyay --init $INIT reported problems (see the log)"
	grep -q "^Init *= *$INIT\$" "$MNT/etc/rcyay.conf" || die "Init = $INIT not in /etc/rcyay.conf"
}

os_locale() {
	sed -i "s/^#\($LOCALE \)/\1/; s/^#\(en_US.UTF-8 \)/\1/" "$MNT/etc/locale.gen"
	in_target locale-gen
	echo "LANG=$LOCALE" >"$MNT/etc/locale.conf"
	echo "KEYMAP=$KEYMAP" >"$MNT/etc/vconsole.conf"
	echo "$HOSTNAME_" >"$MNT/etc/hostname"
	if [[ $INIT == systemd ]]; then
		# see os/arch.sh: a late systemd-vconsole-setup run must not fail the unit
		install -Dm644 /dev/stdin "$MNT/etc/systemd/system/systemd-vconsole-setup.service.d/10-usrside.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/usr/lib/systemd/systemd-vconsole-setup
EOF
	else
		install -Dm644 /dev/stdin "$MNT/etc/usrside/start.d/20-keymap.sh" <<EOF
# UsrsideOS installer: console keymap (systemd-vconsole-setup does not run without systemd)
loadkeys -q $KEYMAP 2>/dev/null || :
EOF
	fi
}

# systemd: systemctl enable; otherwise rcyay-dienste (package service in /etc/sv or translated unit)
os_enable() {
	if [[ $INIT == systemd ]]; then in_target systemctl enable "$@"; return; fi
	rc_target --services enable "$@" >>"$LOG" 2>&1 || die "rcyay --services enable $* failed (see $LOG)"
}

usrside_sv() {   # NAME  – run script from stdin to /etc/sv/NAME/run
	install -Dm755 /dev/stdin "$MNT/etc/sv/$1/run"
}

# iwd only handles Wi-Fi; dhcpcd only wired interfaces, DNS via openresolv
os_services() {
	printf '\n# UsrsideOS: Wi-Fi is configured by iwd\nallowinterfaces en* eth*\n' >>"$MNT/etc/dhcpcd.conf"
	if [[ $INIT == systemd ]]; then
		os_enable iwd dhcpcd chronyd
		return 0
	fi
	# D-Bus system bus (iwd, bluez, polkit): Arch's dbus units are socket activated, so our own service
	usrside_sv dbus <<'EOF'
#!/bin/sh
# UsrsideOS installer: D-Bus system bus without systemd
mkdir -p /run/dbus
dbus-uuidgen --ensure
exec dbus-daemon --system --nofork --nopidfile
EOF
	# tty1: login (autologin into niri with the desktop); BusyBox init has its own tty1 line in /etc/inittab
	local auto=""
	((AUTOLOGIN)) && opt_on desktop && auto="--autologin $USERNAME "
	if [[ $INIT == busybox ]]; then
		sed -i "s|^tty1::respawn:.*|tty1::respawn:/usr/bin/agetty $auto--noclear tty1 linux|" "$MNT/etc/inittab"
		grep -q '^tty1::respawn:/usr/bin/agetty' "$MNT/etc/inittab" || die "/etc/inittab: no tty1 line"
	else
		usrside_sv getty-tty1 <<EOF
#!/bin/sh
exec /usr/bin/agetty $auto--noclear tty1 linux
EOF
	fi
	# without logind: efivarfs (efibootmgr, usrkrnl), XDG_RUNTIME_DIR for every user
	install -Dm644 /dev/stdin "$MNT/etc/usrside/start.d/10-efivarfs.sh" <<'EOF'
# UsrsideOS installer: UEFI variables (efibootmgr, usrkrnl-confirm)
[ -d /sys/firmware/efi/efivars ] && ! mountpoint -q /sys/firmware/efi/efivars && mount -t efivarfs efivarfs /sys/firmware/efi/efivars
:
EOF
	install -Dm644 /dev/stdin "$MNT/etc/usrside/start.d/30-xdg-runtime.sh" <<'EOF'
# UsrsideOS installer: XDG_RUNTIME_DIR without logind (/run/user/UID for every normal user), utmp (who, login)
# (systemd-tmpfiles of usrside-udev runs with -E and skips /run)
[ -e /run/utmp ] || { : >/run/utmp; chgrp utmp /run/utmp; chmod 664 /run/utmp; }
mkdir -p -m 755 /run/user
awk -F: '$3 >= 1000 && $3 < 60000 { print $1, $3 }' /etc/passwd | while read -r u id; do
	mkdir -p -m 700 "/run/user/$id" && chown "$u:" "/run/user/$id"
done
EOF
	install -Dm644 /dev/stdin "$MNT/etc/profile.d/usrside-xdg.sh" <<'EOF'
# UsrsideOS installer: XDG_RUNTIME_DIR without logind (created at boot, /etc/usrside/start.d)
if [ -z "${XDG_RUNTIME_DIR:-}" ] && [ -d "/run/user/$(id -u)" ]; then export XDG_RUNTIME_DIR="/run/user/$(id -u)"; fi
EOF
	# sshd, dhcpcd and getty-ttyS0 are on already (usrside-dienste)
	local s=(dbus iwd chronyd seatd)
	[[ $INIT == busybox ]] || s+=(getty-tty1)
	os_enable "${s[@]}"
}

os_autologin() {
	[[ $INIT == systemd ]] || return 0   # busybox/runit/s6: getty line from os_services
	mkdir -p "$MNT/etc/systemd/system/getty@tty1.service.d"
	printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin %s --noclear %%I $TERM\n' "$USERNAME" \
		>"$MNT/etc/systemd/system/getty@tty1.service.d/autologin.conf"
}

os_extra_services() {
	opt_on bluetooth && os_enable bluetooth
	if opt_on printing; then if [[ $INIT == systemd ]]; then os_enable cups.socket; else os_enable cups; fi; fi
	if opt_on pkgtools; then
		if [[ $INIT == systemd ]]; then os_enable paccache.timer; else log "pkgtools: no timers without systemd, run paccache -r yourself"; fi
	fi
	return 0
}

# PulseAudio is the sound server; PipeWire may only come in as a dependency (portal screen sharing)
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

# systemd: user socket (like Arch); otherwise started with the niri session (like Void), autospawn without niri
os_sound() {
	if [[ $INIT == systemd ]]; then
		in_target systemctl --global enable pulseaudio.socket
	else
		[[ -z $1 ]] || echo 'spawn-at-startup "pulseaudio" "--start" "--exit-idle-time=-1"' >>"$1"
	fi
	wp_no_audio
}

os_community() {
	local f=$MNT/etc/makepkg.conf
	[[ -f $f ]] && sed -i '/^OPTIONS=(/s/\([( ]\)debug\([ )]\)/\1!debug\2/' "$f"
	opt_on yay || return 0
	local aur=() k
	for k in "${!AUR[@]}"; do
		# shellcheck disable=SC2206  # a list of package names
		opt_on "$k" && aur+=(${AUR[$k]})
	done
	aur+=("${EXTRA_AUR[@]}")
	((${#aur[@]})) || return 0
	log "AUR packages with rcyay: ${aur[*]}"
	as_user "rcyay -S --aur --noconfirm --needed --nodiff ${aur[*]}" || die "AUR packages failed (${aur[*]})"
}

# fallback: the kernel of the live system (usrkrnl without initramfs, root fs built in) + its modules;
# its config is the base for usrkrnl (install: kernel picks /boot/config-*)
os_kernel_hook() {
	local k=${LIVE_KERNEL:-} r
	r=$(uname -r)
	[[ -n $k ]] || k=$(ls /boot/vmlinuz-usrkrnl /boot/vmlinuz-* 2>/dev/null | head -n1 || true)
	[[ -f $k ]] || die "no kernel of the live system in /boot (LIVE_KERNEL=FILE)"
	cp "$k" "$MNT/boot/vmlinuz-live"
	if [[ -d /usr/lib/modules/$r ]]; then mkdir -p "$MNT/usr/lib/modules"; cp -a "/usr/lib/modules/$r" "$MNT/usr/lib/modules/"; fi
	if [[ -r /proc/config.gz ]]; then zcat /proc/config.gz >"$MNT/boot/config-live"; fi
	log "fallback kernel: $k ($r) as /boot/vmlinuz-live"
	# a built-in cmdline of the live kernel may carry rootflags=subvol=@ (rcyay images); empty = none
	[[ $ROOT_CMDLINE == *rootflags=* ]] || ROOT_CMDLINE+=" rootflags="
}

os_freeze_kernel() { :; }   # the live kernel copy belongs to no package, nothing updates it

os_hopd_service() {
	if [[ $INIT == systemd ]]; then
		install -Dm644 "$HERE/files/hopd.service" "$MNT/etc/systemd/system/hopd.service"
	else
		install -Dm755 "$HERE/files/hopd.run" "$MNT/etc/sv/hopd/run"
	fi
	os_enable hopd
}

os_confirm_service() {
	if [[ $INIT == systemd ]]; then
		install -Dm644 "$HERE/files/usrkrnl-confirm.service" "$MNT/etc/systemd/system/usrkrnl-confirm.service"
		os_enable usrkrnl-confirm
	else
		install -Dm644 /dev/stdin "$MNT/etc/usrside/start.d/90-usrkrnl-confirm.sh" <<'EOF'
# UsrsideOS installer: make usrkrnl the default after its first boot (usrkrnl-confirm removes this file)
/usr/local/bin/usrkrnl-confirm || :
EOF
	fi
}

os_finish() { :; }   # resolv.conf is written by openresolv (dhcpcd, iwd) from now on
