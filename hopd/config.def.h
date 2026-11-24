/* hopd – Einstellungen. Wie bei dwm: Kopie als config.h anpassen, `make` neu bauen.
 * Der UsrsideOS-Installer setzt die mit @ markierten Werte passend zum Rechner.
 * Lüfterkurven: gemessen am TUXEDO InfinityBook Pro Gen9 (nur dort einschalten). */

static const char nutzer[] = "nutzer"; /* @ */

#if PATCH_STROM
/* ===== strom: je Zustand { Netz, Akku, Akku mit eGPU } =====
 * „Akku mit eGPU“ = Netzteil kommt gleich, nicht bremsen (wie früher bat.sh). */
static const int   strom_pl1[3]      = { 45, 12, 45 }; /* @ */  /* RAPL-Dauerleistung in W (>55 W drosselt binnen Sekunden) */
static const int   strom_pl2[3]      = { 64, 20, 64 }; /* @ */  /* RAPL-Spitze in W */
static const char *strom_epp[3]      = { "balance_performance", "power", "balance_power" };
static const int   strom_maxperf[3]  = { 100, 60, 100 }; /* intel_pstate max_perf_pct */
static const int   strom_turbo[3]    = { 1, 0, 1 };
static const char *strom_profil[3]   = { "performance", "low-power", "balanced" }; /* ACPI platform_profile, falls vorhanden */
static const char *strom_aspm[3]     = { "default", "powersupersave", "powersupersave" };
static const int   strom_nur_e[3]    = { 0, 0, 0 };     /* Programme, IRQs, Workqueues nur auf E-Kernen (Intel-Hybrid, spart ~1 W) @ */
static const int   strom_hell[3]     = { -1, 40, 40 };  /* Helligkeit in %, -1 = nicht anfassen @ */
static const int   strom_writeback[3] = { 500, 1500, 1500 }; /* vm.dirty_writeback_centisecs */
static const int   strom_bt_aus[3]   = { 0, 1, 1 };     /* Bluetooth aus, wenn nichts verbunden ist */
static const char  strom_panel[]     = "eDP-1";         /* niri-Ausgang für die Bildwiederholrate @ */
static const char *strom_modus[3]    = { "", "", "" };  /* z. B. "2560x1600@60"; "" = nicht anfassen @ */
/* USB-Autosuspend: Ausnahmen als "vendor:product". HID/Audio/Drucker sind immer ausgenommen. */
static const char *strom_usb_aus[]   = { NULL };
/* Runtime-PM für alle PCI-Geräte außer diesen Treibern */
static const char *strom_rpm_aus[]   = { "mei_me", "nouveau", "radeon", "nvidia", NULL };
#endif

#if PATCH_LUEFTER
/* ===== luefter (TUXEDO InfinityBook Pro Gen9, Board GXxMRXx) =====
 * Werte 0–200 = 0–100 %; unter 50 hält der Lüfter nicht zuverlässig. Kurve: {°C, Wert}. */
static const char luefter_board[] = "GXxMRXx";
struct punkt { int grad, wert; };
static const struct punkt luefter_akku[] = { { 50, 50 }, { 70, 60 }, { 80, 85 }, { 90, 130 } };
static const struct punkt luefter_netz[] = { { 40, 50 }, { 60, 80 }, { 70, 110 }, { 80, 140 }, { 88, 160 } };
static const struct punkt luefter_egpu[] = { { 45, 70 }, { 60, 100 }, { 70, 130 }, { 80, 160 } };
static const int luefter_an[3]  = { 50, 40, -1 };  /* akku, netz, egpu: ab hier drehen (-1 = immer) */
static const int luefter_aus[3] = { 45, 36, -1 };  /* darunter wieder aus (Abstand gegen Pendeln) */
static const int luefter_not_an = 88, luefter_not_aus = 80;    /* CPU geglättet → 100 % */
static const int luefter_nvme_an = 78, luefter_nvme_aus = 70;  /* SSD → 100 % */
static const int luefter_zweiter = 10;     /* zweiter Lüfter etwas langsamer */
static const double luefter_tau = 15;      /* s Glättung (Paket-Temperatur springt sekündlich) */
static const double luefter_hoch = 3, luefter_runter = 1, luefter_not_hoch = 10; /* Wert/s */
static const int luefter_profil_netz = 3, luefter_profil_akku = 1, luefter_profil_ende = 2; /* EC: 1 Sparen 2 Enthusiast 3 Overboost */
#endif

#if PATCH_EGPU
/* ===== egpu ===== */
static const char egpu_log[] = "/var/log/hopd-egpu.log";
static const int  egpu_versuche = 3;
#endif

#if PATCH_AKKULOG
/* ===== akkulog ===== */
static const char akkulog_datei[] = "/var/lib/hopd/akku.tsv";
static const int  akkulog_takt = 120; /* s */
#endif

#if PATCH_NIRI
/* ===== niri ===== */
static const char niri_panel[] = "eDP-1";   /* Laptop-Panel: Deckel zu → aus @ */
static const char niri_sperre[] = "hyprlock";   /* Sperrprogramm beim Zuklappen (hyprlock, swaylock …) @ */
#endif

