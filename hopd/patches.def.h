/* Welche Patches ins Binary kommen (1 = ja). Der Installer schreibt diese Datei als patches.h. */
#define PATCH_STROM    1  /* Netz/Akku-Profile: RAPL, EPP, Turbo, ASPM, Helligkeit, USB/PCI-Stromsparen */
#define PATCH_LUEFTER  0  /* Lüfterkurven, nur TUXEDO InfinityBook Pro Gen9 (Board GXxMRXx, /dev/tuxedo_io) */
#define PATCH_EGPU     0  /* Thunderbolt-eGPU per UCSI-Reset wecken + Abriss-Protokoll */
#define PATCH_AKKULOG  1  /* Akku-Verbrauch mitschreiben + Auswertung */
#define PATCH_NIRI     0  /* niri-Sitzung: Deckel, Bildwiederholrate, waybar-Start, Sperren (braucht waybar, swaylock, swayidle) */
