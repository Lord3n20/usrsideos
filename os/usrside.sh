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
# live ISO (rcyay M7, bootstrap/iso): the medium; offline mirror usrside/arch/$repo (first in the live mirrorlist),
# finished AUR packages in usrside/repo/usrside-aur, the musl repository in usrside/repo/usrside-musl
USRSIDE_QUELLE=${USRSIDE_QUELLE:-/run/usrside/quelle}

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

usrside_init_path() {
	if [[ $LIBC == musl ]]; then echo "${MUSL_INITS[$1]:-}"; return; fi
	awk -v i="$1" '$1 == i { print $2; exit }' "$USRSIDE_INITS" 2>/dev/null
}

# ---- musl (rcyay M3/M5): own repository usrside-musl (live medium), BusyBox userland, no systemd/AUR/usrkrnl
# init paths of the musl variant (usrside-musl.inits of the rcyay images; the live system is glibc)
declare -A MUSL_INITS=([busybox]=/usr/bin/init [runit]=/usr/bin/runit-init [s6]=/etc/s6-linux-init/current/bin/init)
BASE_OPT=()   # base packages taken when the repository has them (musl: chrony, sudo, efibootmgr)
usrside_musl_repo() {   # directory of the musl repository: medium, or /srv/usrside-musl
	local d
	for d in "${USRSIDE_MUSL_REPO:-}" "$USRSIDE_QUELLE/usrside/repo/usrside-musl" /srv/usrside-musl; do
		[[ -n $d && -e $d/usrside-musl.db ]] && { echo "$d"; return 0; }
	done
	return 1
}
# package tables for LIBC=musl (only what the musl repository has; options without packages drop out)
usrside_libc_tables() {
	[[ $LIBC == musl ]] || return 0
	BASE=(usrside-base usrside-init usrside-busybox usrside-dienste rcyay busybox musl bash filesystem ca-certificates
		runit s6 s6-linux-init dbus seatd openssh dhcpcd openresolv iwd kbd linux-firmware tzdata dosfstools shadow util-linux)
	BASE_OPT=(chrony sudo efibootmgr)   # without chrony: BusyBox ntpd (os_services)
	BUILD_PKGS=(gcc make binutils patch fakeroot pkgconf linux-api-headers)
	CHPASSWD_ARGS="-c sha512"   # BusyBox chpasswd (shadow leaves it out): SHA-512 instead of its DES default
	KERNEL_PKGS=()
	FS_PKG_btrfs=btrfs-progs FS_PKG_xfs="" UCODE_INTEL="" UCODE_AMD=""
	TERMINAL_CMD=foot PRINT_LIVE_TOOLS=0 OS_AUR=0
	AUR=()
	# pipewire provides the pulse layer itself
	PKG=([desktop]="niri foot xwayland-satellite ttf-dejavu mesa adwaita-cursors wl-clipboard"
		[sound]="pipewire wireplumber" [ssh]=openssh [fish]=fish)
}

# prints what is wrong with INIT/LIBC/PROFIL (empty = fine)
usrside_problem() {
	case $INIT in systemd|busybox|runit|s6) ;; *) echo "INIT=$INIT: systemd, busybox, runit or s6"; return ;; esac
	case $LIBC in
		glibc) ;;
		musl)
			[[ $INIT != systemd ]] || { echo "LIBC=musl: no systemd, choose runit, s6 or busybox"; return; }
			[[ ${FS:-btrfs} == btrfs ]] || { echo "LIBC=musl: only btrfs as root file system"; return; }
			((PRINT)) || usrside_musl_repo >/dev/null || { echo "LIBC=musl: no musl repository on the live medium ($USRSIDE_QUELLE/usrside/repo/usrside-musl)"; return; } ;;
		*) echo "LIBC=$LIBC: glibc or musl"; return ;;
	esac
	case $PROFIL in standard|minimal) ;; *) echo "PROFIL=$PROFIL: standard or minimal"; return ;; esac
	[[ -n $(usrside_init_path "$INIT") ]] || echo "INIT=$INIT: no init path in $USRSIDE_INITS of the live system"
}

os_answers() {
	usrside_libc_tables
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
		musl "musl (BusyBox userland, niri + foot; no systemd, AUR, NVIDIA)") && LIBC=$v
	local p; p=$(usrside_problem)
	[[ -z $p ]] || { dlg --msgbox "$p" 8 70; LIBC=glibc; }
	if [[ $LIBC == musl ]]; then usrside_libc_tables; local k; for k in "${!SEL[@]}"; do opt_avail "$k" || SEL[$k]=0; done; fi
	return 0
}

# once before the installation: everything that depends on INIT and the selection
os_prepare() {
	local p ip k
	usrside_libc_tables
	p=$(usrside_problem)
	[[ -z $p ]] || { echo "$p" >&2; return 1; }
	if [[ $LIBC == musl ]]; then
		for k in "${!SEL[@]}"; do opt_avail "$k" || SEL[$k]=0; done
		USRKRNL=0   # no clang/kernel build tools in the musl repository; the live kernel is the kernel
	fi
	if [[ $INIT == systemd ]]; then
		SESSION_CMD="exec niri-session"
		POLKIT_SPAWN='"systemctl" "--user" "start" "hyprpolkitagent"'
	else
		# no logind: libseat talks to seatd, a session bus from dbus-run-session
		SESSION_CMD="export LIBSEAT_BACKEND=seatd; exec dbus-run-session niri --session"
		[[ $LIBC == musl ]] || PKG[polkit]=polkit-gnome   # hyprpolkitagent needs systemd --user
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

# mirrorlist of the live system for the target, without the server lines of the live medium (file://…quelle)
usrside_mirrorlist() {
	local m=/etc/pacman.d/mirrorlist
	grep -q '^Server' "$m" 2>/dev/null || return 0
	if grep '^Server' "$m" | grep -vqF "file://$USRSIDE_QUELLE"; then
		grep -vE "^Server *= *file://$USRSIDE_QUELLE" "$m" >"$MNT/etc/pacman.d/mirrorlist"
	else
		warn "the live mirrorlist only names the medium; set servers in /etc/pacman.d/mirrorlist of the new system"
	fi
}

# no network (install: requirements): fine with the offline mirror of the live medium (first in the mirrorlist)
USRSIDE_OFFLINE=0
os_offline() {
	{ [[ -d $USRSIDE_QUELLE/usrside/arch ]] && grep -q "^Server *= *file://$USRSIDE_QUELLE/" /etc/pacman.d/mirrorlist 2>/dev/null; } \
		|| usrside_musl_repo >/dev/null || return 1
	USRSIDE_OFFLINE=1
	echo "No internet: installing offline from the live medium ($USRSIDE_QUELLE); AUR packages that are not on it are skipped." >&2
}

# offline: packages that the medium's mirror lacks are left out with a note (base packages: abort)
# $@ = pacman command for the target (config, root); changes REPO
usrside_offline_filter() {
	# the sync databases of the medium are the full Arch ones: check that the package files really lie on it
	local miss=() keep=() deps=() n l p b
	while read -r n l; do
		[[ $l == file://* && ! -e ${l#file://} ]] && miss+=("$n")
	done < <(LC_ALL=C "$@" -Sp --print-format '%n %l' "${REPO[@]}" 2>>"$LOG")
	((${#miss[@]})) || return 0
	for p in "${miss[@]}"; do
		for b in "${BASE[@]}"; do [[ $p == "$b" ]] && die "base package $p is not on the live medium (offline mirror incomplete)"; done
		[[ " ${REPO[*]} " == *" $p "* ]] || deps+=("$p")
	done
	((${#deps[@]})) && die "offline: dependencies missing on the live medium: ${deps[*]}"
	for p in "${REPO[@]}"; do [[ " ${miss[*]} " == *" $p "* ]] || keep+=("$p"); done
	REPO=("${keep[@]}")
	warn "offline: not on the live medium, left out: ${miss[*]} (later: rcyay -S ${miss[*]})"
}

# network for the AUR (offline from the live medium: AUR packages only from usrside-aur, the rest is skipped)
usrside_online() {
	if command -v curl >/dev/null; then curl -fsS -m 10 -o /dev/null https://aur.archlinux.org/rpc/v5/info 2>/dev/null
	else wget -q -T 10 -O /dev/null https://aur.archlinux.org/rpc/v5/info 2>/dev/null; fi
}

# AUR packages that lie finished on the live medium (repository usrside-aur): installed with rcyay --root from
# the live system (dependencies from the offline mirror); the repository never enters the target's pacman.conf
# $@ = packages; AUR_REST = those that are not on the medium
usrside_aur_medium() {
	local d=$USRSIDE_QUELLE/usrside/repo/usrside-aur w=/tmp/usrside-install conf have=() p
	AUR_REST=("$@")
	[[ -e $d/usrside-aur.db ]] || return 0
	mkdir -p "$w"; conf=$w/pacman-aur.conf
	{ usrside_pacman_conf "file://$USRSIDE_REPO"; printf '\n[usrside-aur]\nSigLevel = Optional TrustAll\nServer = file://%s\n' "$d"; } >"$conf"
	pacman --config "$conf" -r "$MNT" -Sy >>"$LOG" 2>&1 || { warn "repository usrside-aur on the medium unreadable"; return 0; }
	local list; list=$(pacman --config "$conf" -r "$MNT" -Slq usrside-aur 2>>"$LOG")
	AUR_REST=()
	for p; do if grep -qxF "$p" <<<"$list"; then have+=("$p"); else AUR_REST+=("$p"); fi; done
	if ((${#have[@]})); then
		log "AUR packages from the medium (usrside-aur): ${have[*]}"
		rcyay --config "$conf" --root "$MNT" --rcyayconf "$MNT/etc/rcyay.conf" --noconfirm --repo \
			--cachedir "$MNT/var/cache/pacman/pkg" -S --needed "${have[@]}" >>"$LOG" 2>&1 \
			|| die "AUR packages from the medium failed (${have[*]})"
	fi
	rm -f "$MNT"/var/lib/pacman/sync/usrside-aur.{db,files}
}

usrside_conf_set() {   # KEY VALUE FILE (rcyay.conf, [options])
	if grep -q "^#\?$1 *=" "$3"; then sed -i "0,/^#\?$1 *=.*/s||$1 = $2|" "$3"; else printf '%s = %s\n' "$1" "$2" >>"$3"; fi
}

# rcyay for the target, with its own rcyay.conf (Init, VirtualProvides)
rc_target() { rcyay --root "$MNT" --config "$MNT/etc/pacman.conf" --rcyayconf "$MNT/etc/rcyay.conf" --noconfirm "$@"; }

usrside_musl_pacman_conf() {   # $1 = server of [usrside-musl]
	cat <<EOF
# /etc/pacman.conf – UsrsideOS musl (installer, like rcyay bootstrap/pakete/rcyay)
[options]
HoldPkg     = rcyay musl
Architecture = x86_64_musl
CheckSpace
ParallelDownloads = 5
SigLevel    = Required DatabaseOptional
LocalFileSigLevel = Optional

[usrside-musl]
SigLevel = Never
Server = $1
EOF
}

usrside_bootstrap_musl() {
	local w=/tmp/usrside-install d pkg p g
	d=$(usrside_musl_repo) || die "no musl repository on the live medium"
	log "rcyay --root (musl, $d): ${REPO[*]} (init $INIT)"
	rm -rf "$w"; mkdir -p "$w"
	usrside_musl_pacman_conf "file://$d" >"$w/pacman.conf"
	mkdir -p "$MNT"/{etc,var/lib/pacman,var/cache/pacman/pkg,srv,tmp}
	chmod 1777 "$MNT/tmp"
	chroot_mount
	rm -f "$MNT/etc/resolv.conf"
	pkg=$(ls "$d"/usrside-init-[0-9]*.pkg.tar.* 2>/dev/null | grep -v '\.sig$' | tail -n1)
	[[ -n $pkg ]] || die "usrside-init missing in $d"
	bsdtar -xOf "$pkg" etc/rcyay.conf >"$w/rcyay.conf" || die "no etc/rcyay.conf in $pkg"
	usrside_conf_set Init "$INIT" "$w/rcyay.conf"
	for p in "${BASE_OPT[@]}"; do compgen -G "$d/$p-[0-9]*.pkg.tar.*" >/dev/null && REPO+=("$p"); done
	local P=(pacman --config "$w/pacman.conf" -r "$MNT" --cachedir "$MNT/var/cache/pacman/pkg" --noconfirm)
	local RC=(rcyay --config "$w/pacman.conf" --root "$MNT" --rcyayconf "$w/rcyay.conf" --noconfirm)
	"${P[@]}" -Sy >>"$LOG" 2>&1 || die "pacman -Sy (musl repository) failed, see $LOG"
	usrside_offline_filter "${P[@]}"
	"${RC[@]}" --repo --cachedir "$MNT/var/cache/pacman/pkg" -S --needed "${REPO[@]}" >>"$LOG" 2>&1 \
		|| die "rcyay -S (musl) failed, see $LOG"
	if [[ -s /etc/resolv.conf ]]; then cp -L /etc/resolv.conf "$MNT/etc/resolv.conf"; else printf '# Generated by resolvconf\n' >"$MNT/etc/resolv.conf"; fi
	# the new system: its own copy of the repository, no keyring (the repository is unsigned)
	usrside_musl_pacman_conf "file:///srv/usrside-musl" >"$MNT/etc/pacman.conf"
	rm -rf "$MNT/srv/usrside-musl"; cp -a "$d" "$MNT/srv/usrside-musl"
	cp "$w/rcyay.conf" "$MNT/etc/rcyay.conf"
	# groups that sysusers creates on glibc (no systemd hooks here)
	for g in wheel video input audio seat; do
		grep -q "^$g:" "$MNT/etc/group" || in_target groupadd -r "$g" || warn "group $g could not be created"
	done
	rc_target --init "$INIT" >>"$LOG" 2>&1 || warn "rcyay --init $INIT reported problems (see the log)"
	grep -q "^Init *= *$INIT\$" "$MNT/etc/rcyay.conf" || die "Init = $INIT not in /etc/rcyay.conf"
	[[ -x $MNT${MUSL_INITS[$INIT]} ]] || die "init ${MUSL_INITS[$INIT]} missing in the new system"
}

os_bootstrap() {
	if [[ $LIBC == musl ]]; then usrside_bootstrap_musl; return; fi
	# minimal: the GNU tools stay during the installation and are only replaced by BusyBox at the end (os_finish):
	# package hooks (update-ca-trust: ln -r) and fakeroot (AUR builds; the BusyBox of Arch is static, LD_PRELOAD
	# cannot reach it) need them
	local w=/tmp/usrside-install vprov="which" i pkg
	log "rcyay --root: ${REPO[*]} (init $INIT, userland $PROFIL)"
	((USRSIDE_OFFLINE)) && log "offline installation from the live medium ($USRSIDE_QUELLE)"
	rm -rf "$w"; mkdir -p "$w"
	usrside_pacman_conf "file://$USRSIDE_REPO" >"$w/pacman.conf"
	# usr/lib/modules: the DKMS hook of the packages (nvidia-open-dkms …) aborts without it
	mkdir -p "$MNT"/{etc,var/lib/pacman,var/cache/pacman/pkg,srv,tmp,usr/lib/modules}
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
	((USRSIDE_OFFLINE)) && usrside_offline_filter "${P[@]}"
	for i in 1 2; do   # one retry for slow mirrors / weak Wi-Fi; finished downloads stay in the cache
		"${RC[@]}" --repo --cachedir "$MNT/var/cache/pacman/pkg" -S --needed "${REPO[@]}" >>"$LOG" 2>&1 && break
		((i == 2)) && die "rcyay -S failed twice (network/mirrors? see $LOG)"
		log "rcyay -S failed, refreshing the databases and retrying once"
		"${P[@]}" -Syy >>"$LOG" 2>&1 || true
	done
	"${RC[@]}" --provides apply >>"$LOG" 2>&1 || die "rcyay --provides apply failed"
	if [[ -s /etc/resolv.conf ]]; then cp -L /etc/resolv.conf "$MNT/etc/resolv.conf"; else printf '# Generated by resolvconf\n' >"$MNT/etc/resolv.conf"; fi   # offline: none

	# the new system: same repositories, [usrside] as a local copy, own keyring, Init
	usrside_pacman_conf "file://$USRSIDE_REPO" >"$MNT/etc/pacman.conf"
	usrside_mirrorlist
	rm -rf "$MNT$USRSIDE_REPO"; cp -a "$USRSIDE_REPO" "$MNT$USRSIDE_REPO"
	cp "$w/rcyay.conf" "$MNT/etc/rcyay.conf"
	[[ $PROFIL == minimal ]] && usrside_conf_set VirtualProvides "which coreutils findutils grep sed gawk awk diffutils" "$MNT/etc/rcyay.conf"
	in_target pacman-key --init || die "pacman-key --init failed"
	in_target pacman-key --populate archlinux || die "pacman-key --populate failed"
	in_target gpgconf --homedir /etc/pacman.d/gnupg --kill all || true
	rm -f "$MNT"/etc/pacman.d/gnupg/S.*
	# services of all installed units for the chosen init (systemd: nothing generated)
	rc_target --init "$INIT" >>"$LOG" 2>&1 || warn "rcyay --init $INIT reported problems (see the log)"
	grep -q "^Init *= *$INIT\$" "$MNT/etc/rcyay.conf" || die "Init = $INIT not in /etc/rcyay.conf"
}

os_locale() {
	if [[ $LIBC == musl ]]; then   # musl: no locale-gen, LANG is enough
		echo "LANG=$LOCALE" >"$MNT/etc/locale.conf"; echo "KEYMAP=$KEYMAP" >"$MNT/etc/vconsole.conf"; echo "$HOSTNAME_" >"$MNT/etc/hostname"
		install -Dm644 /dev/stdin "$MNT/etc/usrside/start.d/20-keymap.sh" <<<"loadkeys -q $KEYMAP 2>/dev/null || :"
		return 0
	fi
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
# UsrsideOS installer: XDG_RUNTIME_DIR without logind (/run/user/UID for every normal user)
# (/run/utmp comes from systemd-tmpfiles in usrside-udev >= 2026.11.26-2)
mkdir -p -m 755 /run/user
awk -F: '$3 >= 1000 && $3 < 60000 { print $1, $3 }' /etc/passwd | while read -r u id; do
	mkdir -p -m 700 "/run/user/$id" && chown "$u:" "/run/user/$id"
done
EOF
	# musl: no usrside-udev (systemd-tmpfiles), so utmp from here (who, login records)
	if [[ $LIBC == musl ]]; then
		install -Dm644 /dev/stdin "$MNT/etc/usrside/start.d/25-utmp.sh" <<<'[ -e /run/utmp ] || { : >/run/utmp; chgrp utmp /run/utmp 2>/dev/null; chmod 664 /run/utmp; }'
	fi
	install -Dm644 /dev/stdin "$MNT/etc/profile.d/usrside-xdg.sh" <<'EOF'
# UsrsideOS installer: XDG_RUNTIME_DIR without logind (created at boot, /etc/usrside/start.d)
if [ -z "${XDG_RUNTIME_DIR:-}" ] && [ -d "/run/user/$(id -u)" ]; then export XDG_RUNTIME_DIR="/run/user/$(id -u)"; fi
EOF
	# sshd, dhcpcd and getty-ttyS0 are on already (usrside-dienste)
	# iwd without systemd unit (musl package): own service, after the system bus
	if [[ ! -e $MNT/usr/lib/systemd/system/iwd.service && ! -e $MNT/etc/sv/iwd/run ]]; then
		usrside_sv iwd <<'SV'
#!/bin/sh
# UsrsideOS installer: iwd without systemd unit (needs the D-Bus system bus)
[ -S /run/dbus/system_bus_socket ] || { sleep 1; exit 1; }
# iwd stops without /dev/rfkill; mdev does not load modules by modalias like udev
modprobe -q rfkill 2>/dev/null; modprobe -q cfg80211 2>/dev/null
exec /usr/lib/iwd/iwd
SV
	fi
	local s=(dbus iwd seatd)
	if [[ -x $MNT/usr/bin/chronyd ]]; then s+=(chronyd)
	elif [[ -x $MNT/usr/bin/busybox ]]; then   # no chrony (musl): BusyBox ntpd
		usrside_sv ntpd <<'SV'
#!/bin/sh
# UsrsideOS installer: time with BusyBox ntpd (no chrony)
exec busybox ntpd -n -p pool.ntp.org
SV
		s+=(ntpd)
	fi
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
	# boltd is started by D-Bus activation; without systemd nobody creates its StateDirectory=
	if opt_on bolt && [[ $INIT != systemd ]]; then install -dm755 "$MNT/var/lib/boltd"; fi
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
	if [[ $LIBC == musl ]]; then   # PipeWire (with its pulse layer) instead of PulseAudio, started by niri
		[[ -z $1 ]] || printf 'spawn-at-startup "pipewire"\nspawn-at-startup "wireplumber"\nspawn-at-startup "pipewire-pulse"\n' >>"$1"
		return 0
	fi
	if [[ $INIT == systemd ]]; then
		in_target systemctl --global enable pulseaudio.socket
	else
		[[ -z $1 ]] || echo 'spawn-at-startup "pulseaudio" "--start" "--exit-idle-time=-1"' >>"$1"
	fi
	wp_no_audio
}

# DKMS sources (nvidia-open-dkms, tuxedo-drivers-dkms) are only added by the package hook when a kernel is
# installed; there is none yet, so add them here: usrkrnl/setup then builds them (dkms autoinstall -k)
usrside_dkms_add() {
	local d m
	[[ -x $MNT/usr/bin/dkms ]] || return 0
	for d in "$MNT"/usr/src/*/dkms.conf; do
		[[ -f $d ]] || continue
		m=${d%/dkms.conf}; m=${m##*/}
		os_chroot dkms status "${m%-*}/${m##*-}" 2>/dev/null | grep -q . && continue
		in_target dkms add "/usr/src/$m" || warn "dkms add $m failed (see the log)"
	done
	return 0
}

os_community() {
	local f=$MNT/etc/makepkg.conf
	[[ -f $f ]] && sed -i '/^OPTIONS=(/s/\([( ]\)debug\([ )]\)/\1!debug\2/' "$f"
	usrside_dkms_add
	opt_on yay || return 0
	local aur=() k
	for k in "${!AUR[@]}"; do
		# shellcheck disable=SC2206  # a list of package names
		opt_on "$k" && aur+=(${AUR[$k]})
	done
	aur+=("${EXTRA_AUR[@]}")
	((${#aur[@]})) || return 0
	usrside_aur_medium "${aur[@]}"; aur=("${AUR_REST[@]}")
	if ((${#aur[@]})); then
		if usrside_online; then
			log "AUR packages with rcyay: ${aur[*]}"
			as_user "rcyay -S --aur --noconfirm --needed --nodiff ${aur[*]}" || die "AUR packages failed (${aur[*]})"
		else
			warn "no network: AUR packages skipped (${aur[*]}); later: rcyay -S --aur ${aur[*]}"
		fi
	fi
	usrside_dkms_add
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
	# without kmod (musl: BusyBox modprobe) compressed modules cannot be loaded: unpack them, new modules.dep
	if [[ -d $MNT/usr/lib/modules/$r && ! -x $MNT/usr/bin/kmod ]] && command -v zstd >/dev/null; then
		find "$MNT/usr/lib/modules/$r" -name '*.ko.zst' -exec zstd -qd --rm {} + \
			&& { in_target depmod -a "$r" || warn "depmod $r failed in the new system"; } \
			|| warn "kernel modules could not be unpacked (BusyBox modprobe cannot load .ko.zst)"
	fi
	if [[ -r /proc/config.gz ]]; then zcat /proc/config.gz >"$MNT/boot/config-live"; fi
	log "fallback kernel: $k ($r) as /boot/vmlinuz-live"
	# a built-in cmdline of the live kernel may carry rootflags=subvol=@ (rcyay images); empty = none
	[[ $ROOT_CMDLINE == *rootflags=* ]] || ROOT_CMDLINE+=" rootflags="
	# usrkrnl offline: the Linux source of the live medium (usrside/quellen/linux-KVER.tar.xz) instead of kernel.org
	local kv t d
	kv=$(sed -n 's/^KVER=//p' "$HERE/usrkrnl/setup" | head -n1)
	t=$USRSIDE_QUELLE/usrside/quellen/linux-$kv.tar.xz
	if [[ ${USRKRNL:-0} == 1 && -n $kv && -s $t ]]; then
		d=$MNT/home/$USERNAME/.local/src/usrkrnl
		mkdir -p "$d" && cp "$t" "$d/" && chroot_run chown -R "$USERNAME:" "/home/$USERNAME/.local" \
			&& log "usrkrnl: Linux $kv from the medium ($t)" || warn "usrkrnl: copying $t failed (download instead)"
	fi
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

# resolv.conf belongs to openresolv (dhcpcd, iwd) from now on: a real file with only its signature line,
# never empty or foreign (otherwise "resolvconf: signature mismatch" and no DNS after the first boot)
os_finish() {
	if [[ $LIBC != musl && $PROFIL == minimal ]]; then   # last step: BusyBox instead of the GNU tools
		if rc_target --provides apply >>"$LOG" 2>&1; then
			opt_on yay && warn "userland minimal: AUR builds need the GNU tools again (fakeroot cannot intercept the static BusyBox): rcyay -S coreutils before, rcyay --provides apply after"
		else warn "userland minimal: rcyay --provides apply failed, the GNU tools stay (see the log)"; fi
	fi
	rm -f "$MNT/etc/resolv.conf"
	printf '# Generated by resolvconf\n' >"$MNT/etc/resolv.conf"
}
