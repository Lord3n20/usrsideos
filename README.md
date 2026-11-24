# UsrsideOS

Ein sehr kleines Arch-Linux-System mit eigenem Kernel ([usrkrnl](https://github.com/Lord3n20/usrkrnl)),
das beim Installieren auf den Rechner zugeschnitten wird.

**Vorinstalliert:** yay · niri · kitty · ungoogled-chromium · hopd · iwd · usrkrnl.
Alles andere wählt man im Installer dazu (wie bei archinstall) oder installiert es später mit `pacman`/`yay`.

## Installieren

Arch-Linux-ISO im **UEFI-Modus** starten, dann:

```sh
iwctl station wlan0 connect MEIN-WLAN     # nur bei WLAN
pacman -Sy --noconfirm git
git clone https://github.com/Lord3n20/usrsideos
usrsideos/install
```

Im Menü Festplatte, Benutzer usw. einstellen, dann **Installieren**. Die Festplatte wird
komplett gelöscht: 1 GiB EFI-Partition und der Rest als btrfs (`@`, `@home`, zstd-Kompression).

| Menüpunkt | Was passiert |
|---|---|
| Autologin + niri | tty1 meldet sich selbst an und startet `niri-session` |
| hopd | Nur die gewählten Teile werden einkompiliert, Werte (Watt, Helligkeit, Panel) werden abgefragt |
| Zusatzpakete | Ton, waybar, fuzzel, mako, Sperrbildschirm, Bluetooth, NVIDIA … oder eigene Pakete (`aur:` davor = AUR) |
| usrkrnl bauen | Kernel nur mit den Treibern dieses Rechners, BORE, clang ThinLTO, ohne initramfs (10–40 min) |

## Starten

- Der Arch-Kernel (mit initramfs) ist immer als Notfall-Eintrag „UsrsideOS (Arch-Kernel)“ da.
- Der erste Neustart nimmt **einmal** usrkrnl. Klappt der Start, macht `usrkrnl-bestaetigen`
  ihn zum Standard. Klappt er nicht, startet beim nächsten Mal wieder der Arch-Kernel.
- Neue Hardware später? Gerät einstecken, benutzen, dann `cd ~/usrkrnl && usrkrnl/setup`.

## hopd

Ein kleiner Daemon in C (Stil dwm: Einstellungen in `config.h`, Teile in `patches.h`, neu bauen mit `make`).
Liegt nach der Installation in `/usr/local/src/hopd`.

| Teil | Wofür |
|---|---|
| strom | Profile für Netz / Akku / Akku mit eGPU: RAPL-Leistung, EPP, Turbo, ASPM, Helligkeit, USB- und PCI-Stromsparen |
| akkulog | Akku-Verbrauch mitschreiben, Auswertung mit `akku-log report` |
| luefter | Lüfterkurven, nur TUXEDO InfinityBook Pro Gen9 |
| egpu | Thunderbolt-eGPU wecken, Abrisse protokollieren |
| niri | Deckel, Bildwiederholrate je Netz/Akku, waybar-Start, Sperren |

Befehle: `hopd befehle`; ändern: `/usr/local/src/hopd/config.h` bearbeiten, dann
`sudo make -C /usr/local/src/hopd install && sudo systemctl restart hopd`.

## Grenzen

- Nur x86_64 mit UEFI. Keine Festplattenverschlüsselung (usrkrnl startet ohne initramfs).
- Der Installer löscht die gewählte Festplatte komplett, kein Dual-Boot.
