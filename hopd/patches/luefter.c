/* Patch luefter – Lüftersteuerung InfinityBook Pro Gen9 über /dev/tuxedo_io (tuxedo-drivers),
 * ohne TUXEDO Control Center. Kurven, Glättung, Notzweig und Protokoll wie das frühere
 * Python-Programm; Status/Modus bleiben in /run/luefter (Waybar liest sie).
 *   hopd luefter [status|frei|modus auto|leise|kuehl|werk|naechster]  (Symlink luefter) */

#define L_RUN "/run/luefter"
enum { L_AKKU, L_NETZ, L_EGPU };
static const char *l_profilname[] = { "akku", "netz", "egpu" };
static const char *l_modi[] = { "auto", "leise", "kuehl", "werk" };
static int l_fd = -1, l_aus;
static double l_bereit_bis;

#define L_IO(r, typ, nr, gr) (((unsigned long)(r) << 30) | ((unsigned long)(gr) << 16) | ((typ) << 8) | (nr))
#define L_RD 0xEF
#define L_WR 0xF0
#define L_ALLG 0xEC

static long l_lies(int nr)
{
	int64_t b = 0;
	if (ioctl(l_fd, L_IO(2, L_RD, nr, 8), &b) < 0) return -1;
	return (int32_t)b;
}
static void l_ioctl_w(int nr, int64_t v) { if (!trocken) ioctl(l_fd, L_IO(1, L_WR, nr, 8), &v); else meld("  lüfter-ioctl %#x ← %lld", nr, (long long)v); }
static void l_setze(int w)
{
	int z = (w == 0 || w == 200) ? w : (w - luefter_zweiter < 50 ? 50 : w - luefter_zweiter);
	l_ioctl_w(0x10, w); l_ioctl_w(0x11, z);
}
static void l_frei(void) { if (!trocken) ioctl(l_fd, L_IO(0, L_WR, 0x14, 0), 0); }
static int l_ec_profil(void) { long r = l_lies(0x14); return r & 0xa0 ? 1 : r & 0x10 ? 3 : 2; }
static int l_bereit(void) { int64_t b = 0; return ioctl(l_fd, L_IO(2, L_ALLG, 0x06, 8), &b) == 0 && (int32_t)b == 1; }

static int l_oeffnen(void)
{
	if (l_fd >= 0) return 1;
	if ((l_fd = open("/dev/tuxedo_io", O_RDONLY | O_CLOEXEC)) < 0) return 0;
	/* Treiber setzt seine Geräteinfos erst hier – vorher führt Lesen zu einem Kernel-Oops */
	if (!l_bereit()) { close(l_fd); l_fd = -1; return 0; }
	return 1;
}

static const char *hwmon(const char *name, char *b, size_t n)
{
	char p[300], t[32];
	b[0] = 0;
	JEDES(h, "/sys/class/hwmon/hwmon*") {
		snprintf(p, sizeof p, "%s/name", h);
		if (lies(p, t, sizeof t) > 0 && !strcmp(t, name) && !*b) snprintf(b, n, "%s/temp1_input", h);
	}
	return *b ? b : NULL;
}
static int rund(double x) { return (int)(x + 0.5); }
static double kurve(const struct punkt *k, size_t n, double t)
{
	if (t <= k[0].grad) return k[0].wert;
	for (size_t i = 1; i < n; i++)
		if (t <= k[i].grad) return k[i - 1].wert + (k[i].wert - k[i - 1].wert) * (t - k[i - 1].grad) / (k[i].grad - k[i - 1].grad);
	return k[n - 1].wert;
}
static int l_modus(void)
{
	char b[16];
	if (lies(L_RUN "/modus", b, sizeof b) > 0)
		for (size_t i = 0; i < LEN(l_modi); i++) if (!strcmp(b, l_modi[i])) return (int)i;
	return 0;
}
static void spitzenreiter(char *aus, size_t n)
{
	static struct pz a[4096], b[4096]; struct verbr v[64];
	int na = prozesse(a, 4096); schlaf(0.5);
	int nb = prozesse(b, 4096), k = verbrauch(a, na, b, nb, 0.5, v, 64);
	size_t o = 0; aus[0] = 0;
	for (int i = 0; i < k && i < 3; i++) o += snprintf(aus + o, n - o, "%s%s %.0f %%", i ? ", " : "", v[i].name, v[i].pct);
}

/* Zustand der Regelung */
static char l_cpu[300], l_nvme[300];
static double l_t, l_nv, l_wert = -1, l_zuletzt, l_nvme_zeit, l_alt, l_profil_zeit = -1e9, l_rapl_zeit = -1e9, l_fremd;
static int l_geschr = -1, l_not, l_frei_an, l_hoch, l_profil_netz = -1;
static char l_status[64];

static void luefter_start(void)
{
	char b[64];
	lies("/sys/class/dmi/id/board_name", b, sizeof b);
	if (strcmp(b, luefter_board)) { meld("luefter: Board %s statt %s – Patch aus", b, luefter_board); l_aus = 1; return; }
	if (!trocken) {
		mkdir(L_RUN, 0755);
		if (!da(L_RUN "/modus")) datei_ersetzen(L_RUN "/modus", "auto\n", 0666);
		chmod(L_RUN "/modus", 0666); /* Modus ohne sudo umschaltbar (Waybar) */
	}
	l_bereit_bis = jetzt() + 30;
}

static double luefter_tick(double t)
{
	if (l_aus) return 3600;
	if (l_fd < 0) {
		if (!l_oeffnen()) {
			if (t > l_bereit_bis) { meld("luefter: /dev/tuxedo_io nicht bereit – Firmware regelt"); return 60; }
			return 1;
		}
		hwmon("coretemp", l_cpu, sizeof l_cpu); hwmon("nvme", l_nvme, sizeof l_nvme);
		l_t = lies_zahl(l_cpu, 50000) / 1000.0;
		l_nv = *l_nvme ? lies_zahl(l_nvme, 0) / 1000.0 : 0;
		l_alt = l_nvme_zeit = t;
		meld("luefter: übernimmt");
	}
	double dt = t - l_alt; if (dt < 0.1) dt = 0.1;
	l_alt = t;
	double roh = lies_zahl(l_cpu, 50000) / 1000.0, f = dt / luefter_tau;
	l_t += (roh - l_t) * (f > 1 ? 1 : f);
	if (*l_nvme && t - l_nvme_zeit >= 60) { l_nv = lies_zahl(l_nvme, 0) / 1000.0; l_nvme_zeit = t; } /* weckt sonst die SSD */

	int modus = l_modus(), netz = am_netz(), eg = egpu_da();
	if (t - l_profil_zeit >= 30 || netz != l_profil_netz) {
		int soll = netz ? luefter_profil_netz : luefter_profil_akku, ist = l_ec_profil();
		if (ist != soll) { l_ioctl_w(0x18, soll); meld("Leistungsprofil %d → %d (%s)", ist, soll, netz ? "Netz" : "Akku"); }
		l_profil_zeit = t; l_profil_netz = netz;
	}
#if PATCH_STROM
	/* EC setzt RAPL nach dem Profilwechsel (verzögert) zurück → kurz danach und dann alle 30 s prüfen */
	if (strom_zustand >= 0 && t - l_rapl_zeit >= (t - l_profil_zeit < 10 ? 1 : 30)) { strom_rapl(strom_zustand, 1); l_rapl_zeit = t; }
#endif
	int pr = modus == 1 ? L_AKKU : modus == 2 ? L_EGPU : eg ? L_EGPU : netz ? L_NETZ : L_AKKU;
	const char *name = l_profilname[pr];
	int not_vorher = l_not;
	l_not = l_not ? (l_t >= luefter_not_aus || l_nv >= luefter_nvme_aus) : (l_t >= luefter_not_an || l_nv >= luefter_nvme_an);
	if (l_not != not_vorher)
		meld("Notzweig %s: CPU geglättet %.1f °C, roh %.0f °C, SSD %.0f °C, %s, eGPU %s",
		     l_not ? "AN" : "aus", l_t, roh, l_nv, netz ? "Netz" : "Akku", eg ? "ja" : "nein");

	if (modus == 3) { /* werk: Firmware regelt */
		if (!l_frei_an) { l_frei(); l_frei_an = 1; l_wert = -1; l_geschr = -1; }
		name = "werk";
	} else {
		static const struct punkt *k[] = { luefter_akku, luefter_netz, luefter_egpu };
		static const size_t kn[] = { LEN(luefter_akku), LEN(luefter_netz), LEN(luefter_egpu) };
		double ziel, kv = kurve(k[pr], kn[pr], l_t);
		l_frei_an = 0;
		if (l_wert < 0) l_wert = l_lies(0x10);
		if (l_not) { ziel = 200; name = "not"; }
		else if (luefter_an[pr] < 0) ziel = kv;
		else if (l_wert == 0) ziel = l_t >= luefter_an[pr] ? kv : 0;
		else ziel = l_t <= luefter_aus[pr] ? 0 : kv;
		ziel = rund(ziel / 5) * 5;
		if (ziel == 0) l_wert = 0;
		else if (ziel > l_wert) { double w = l_wert + (l_not ? luefter_not_hoch : luefter_hoch) * dt; if (w > ziel) w = ziel; l_wert = w < 50 ? 50 : w; }
		else if (ziel <= l_wert - 10) { double w = l_wert - luefter_runter * dt; l_wert = w < ziel ? ziel : w; }
		int soll = l_wert ? rund(l_wert / 5) * 5 : 0;
		if (soll != l_geschr || t - l_zuletzt >= 30) { l_setze(soll); l_geschr = soll; l_zuletzt = t; }
	}
	if (!l_frei_an && l_geschr >= 0) {
		if (l_geschr >= 100 && !l_hoch) {
			char top[160]; spitzenreiter(top, sizeof top);
			meld("Lüfter hoch %d %% (%s): CPU geglättet %.1f °C, roh %.0f °C, SSD %.0f °C, eGPU %s; CPU: %s",
			     l_geschr / 2, name, l_t, roh, l_nv, eg ? "ja" : "nein", top);
		}
		l_hoch = l_geschr >= 80 && (l_hoch || l_geschr >= 100);
		long ist = l_lies(0x10);
		if (ist >= l_geschr + 40) { /* Firmware dreht an uns vorbei → sofort zurücksetzen */
			if (t - l_fremd >= 60) { meld("Firmware dreht selbst: ist %ld %%, gesetzt %d %%, CPU %.1f °C", ist / 2, l_geschr / 2, l_t); l_fremd = t; }
			l_setze(l_geschr); l_zuletzt = t;
		}
	}
	char st[64];
	snprintf(st, sizeof st, "%s %s %ld\n", l_modi[modus], name, (l_geschr >= 0 ? l_geschr : l_lies(0x10)) / 2);
	if (strcmp(st, l_status)) { datei_ersetzen(L_RUN "/status", st, 0644); strcpy(l_status, st); }
	return netz ? 2 : 5;
}

static void luefter_ende(void)
{
	if (l_fd < 0) return;
	l_frei(); l_ioctl_w(0x18, luefter_profil_ende);
}

static int luefter_befehl(int argc, char **argv)
{
	const char *a = argc > 1 ? argv[1] : "status";
	char b[64];
	if (!strcmp(a, "status")) { if (lies(L_RUN "/status", b, sizeof b) < 0) stirb("Dienst läuft nicht"); puts(b); return 0; }
	if (!strcmp(a, "frei")) { if (!l_oeffnen()) stirb("/dev/tuxedo_io fehlt"); l_frei(); return 0; }
	if (!strcmp(a, "modus") && argc == 3) {
		int m = -1;
		if (!strcmp(argv[2], "naechster")) m = (l_modus() + 1) % (int)LEN(l_modi);
		else for (size_t i = 0; i < LEN(l_modi); i++) if (!strcmp(argv[2], l_modi[i])) m = (int)i;
		if (m < 0) stirb("Modi: auto leise kuehl werk naechster");
		snprintf(b, sizeof b, "%s\n", l_modi[m]);
		if (trocken) { meld("  modus ← %s", l_modi[m]); return 0; }
		int fd = open(L_RUN "/modus", O_WRONLY | O_TRUNC);
		if (fd < 0 || write(fd, b, strlen(b)) < 0) stirb("%s/modus: %s", L_RUN, strerror(errno));
		close(fd);
		return 0;
	}
	stirb("luefter status|frei|modus auto|leise|kuehl|werk|naechster");
	return 2;
}

static struct patch p_luefter = { .name = "luefter", .start = luefter_start, .tick = luefter_tick, .ende = luefter_ende };
#define LUEFTER_BEFEHLE { "luefter", luefter_befehl, "Lüfter: status|frei|modus …" },
