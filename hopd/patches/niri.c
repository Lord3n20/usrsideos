/* Patch niri – alles rund um die niri-Sitzung in hopd statt in Einzelskripten.
 * Ersetzt ~/.config/niri/{start,gpu-wahl,deckel,schein-aus}.sh und waybar/scripts/power-watch.sh.
 *
 * Als Nutzer:
 *   hopd niri-start   aus ~/.bashrc auf tty1: GPU wählen, niri starten; Mod+Shift+G (legt
 *                     $XDG_RUNTIME_DIR/niri-neustart an) → GPU neu wählen, niri neu starten
 *   hopd gpu-wahl     eGPU (NVIDIA) wenn angesteckt, sonst Intel → ~/.config/niri/gpu.kdl
 *   hopd sitzung      spawn-at-startup: Bildwiederholrate + Deckel richtig setzen, dann waybar
 *                     und netz-autostart (früher power-watch.sh + udevadm-Schleife), mit Patch ton den HDMI-EQ
 *   hopd schein-aus   Mod+Shift+L: sperren, Bildschirme aus, nach 3 s ohne Eingabe wieder aus
 * Im Dienst (root):
 *   Deckel über den Deckelschalter (evdev SW_LID, ohne Abfrage-Schleife, ohne ACPI-Wettlauf):
 *   zu → Panel aus, auf → Panel an; meldet sich ein Monitor neu an (drm-uevent), während der
 *   Deckel zu ist, wird das Panel gleich wieder ausgeschaltet. */
#include <linux/input.h>

/* ---------- gpu-wahl ---------- */
#define TC "/sys/class/typec"
static int n_renderknoten(char *aus, size_t n)
{
	char p[300], t[32];
	JEDES(r, "/dev/dri/renderD*") {
		snprintf(p, sizeof p, "/sys/class/drm/%s/device", strrchr(r, '/') + 1);
		if (!*aus && !strcmp(treiber(p, t, sizeof t), "nvidia")) snprintf(aus, n, "%s", r);
	}
	return *aus != 0;
}
static int n_tb_geraet(void)
{
	DIR *d = opendir("/sys/bus/thunderbolt/devices"); struct dirent *e; int ja = 0;
	while (d && (e = readdir(d)) && !ja) {
		const char *s = e->d_name;
		if (!isdigit((unsigned char)*s)) continue;
		while (isdigit((unsigned char)*s)) s++;
		ja = s[0] == '-' && s[1] >= '1' && s[1] <= '9' && !s[2];
	}
	if (d) closedir(d);
	return ja;
}
static int n_tb_partner(void)
{
	char b[16];
	JEDES(s, TC "/port0-partner/*/svid") if (lies(s, b, sizeof b) > 0 && strstr(b, "8087")) return 1;
	return 0;
}
static int gpu_wahl(int argc, char **argv)
{
	char dir[300], p[340], gpu[64] = "";
	snprintf(dir, sizeof dir, "%s/.config/niri", getenv("HOME") ? getenv("HOME") : "/root");
	snprintf(p, sizeof p, "%s/nur-intel", dir);
	if (!da(p)) {
		/* Schnellstart: ob eine eGPU steckt, weiß erst UCSI (Port 0 ≈ 3,5 s nach Kernelstart).
		 * Port abwarten (max 2 s), kein Partner → sofort Intel; Partner ohne Altmodes → max 1 s;
		 * nur bei TB-Partner (SVID 8087) auf egpu-weck und den NVIDIA-Treiber warten. */
		for (int i = 0; i < 40 && !da(TC "/port0"); i++) schlaf(0.05);
		if (da(TC "/port0-partner")) {
			for (int i = 0, ok = 0; i < 20 && !ok; i++) { JEDES(x, TC "/port0-partner/port0-partner.*") { (void)x; ok = 1; } if (!ok) schlaf(0.05); }
			if (n_tb_partner()) {
				for (int i = 0; i < 5 && !da("/run/hopd/egpu-laeuft") && !da("/run/hopd/egpu-fertig"); i++) schlaf(0.2);
				for (int i = 0; i < 125 && da("/run/hopd/egpu-laeuft"); i++) schlaf(0.2);
			}
		}
		n_renderknoten(gpu, sizeof gpu);
		if (!*gpu && n_tb_geraet()) for (int i = 0; i < 20 && !n_renderknoten(gpu, sizeof gpu); i++) schlaf(0.5);
	}
	char k[256];
	snprintf(k, sizeof k, "// Automatisch von hopd gpu-wahl erzeugt – nicht von Hand ändern.\ndebug {\n  honor-xdg-activation-with-invalid-serial\n%s%s%s}\n",
	         *gpu ? "  render-drm-device \"" : "", gpu, *gpu ? "\"\n" : "");
	snprintf(p, sizeof p, "%s/gpu.kdl", dir);
	datei_ersetzen(p, k, 0644);
	printf("niri rendert auf: %s\n", *gpu ? gpu : "Intel (iGPU)");
	return 0;
}

/* ---------- niri-start ---------- */
static int niri_start(int argc, char **argv)
{
	char neu[300]; const char *rt = getenv("XDG_RUNTIME_DIR");
	snprintf(neu, sizeof neu, "%s/niri-neustart", rt ? rt : "/tmp");
	setenv("NIRI_ERSTSTART", "1", 1); /* nur beim ersten Start sperren, nicht nach Mod+Shift+G */
	for (;;) {
		unlink(neu);
		gpu_wahl(0, NULL);
		if (trocken) { meld("  starte niri --session"); return 0; }
		pid_t p = fork();
		if (p == 0) { execlp("niri", "niri", "--session", (char *)NULL); _exit(127); }
		if (p > 0) waitpid(p, NULL, 0);
		setenv("NIRI_ERSTSTART", "0", 1);
		if (!da(neu)) return 0; /* kein Neustart-Wunsch → Sitzung endet, getty meldet neu an */
	}
}

/* ---------- Hilfen für die Sitzung (laufen als Nutzer in niri) ---------- */
static pid_t n_los(char *const argv[], const char *log) /* im Hintergrund, eigene Sitzung */
{
	if (trocken) { starte(argv); return 0; }
	pid_t p = fork();
	if (p == 0) {
		setsid();
		int n = open("/dev/null", O_RDWR), l = log ? open(log, O_WRONLY | O_CREAT | O_TRUNC, 0644) : -1;
		dup2(n, 0); dup2(l >= 0 ? l : n, 1); dup2(l >= 0 ? l : n, 2);
		execvp(argv[0], argv); _exit(127);
	}
	return p;
}
static int n_deckel_zu(void) { char b[64] = ""; JEDES(s, "/proc/acpi/button/lid/*/state") lies(s, b, sizeof b); return strstr(b, "closed") != NULL; }
static int n_laeuft(const char *name)
{
	char p[64], c[32]; DIR *d = opendir("/proc"); struct dirent *e; int ja = 0;
	while (d && (e = readdir(d)) && !ja) if (isdigit((unsigned char)e->d_name[0])) {
		snprintf(p, sizeof p, "/proc/%s/comm", e->d_name);
		ja = lies(p, c, sizeof c) > 0 && !strcmp(c, name);
	}
	if (d) closedir(d);
	return ja;
}

static int sitzung(int argc, char **argv)
{
	char log[300], ns[300]; const char *h = getenv("HOME");
	/* 1. Panel passend zu Netz/Akku und Deckel, bevor waybar seine Leiste anlegt */
	if (n_deckel_zu()) STARTE("niri", "msg", "output", (char *)niri_panel, "off");
#if PATCH_STROM
	else {
		int z = am_netz() ? NETZ : egpu_da() ? AKKU_EGPU : AKKU;
		if (*strom_modus[z]) STARTE("niri", "msg", "output", (char *)strom_panel, "mode", (char *)strom_modus[z]);
	}
#endif
	schlaf(1);
	/* 2. waybar (Netzteil-Wechsel meldet ab jetzt der hopd-Dienst per Signal) */
	snprintf(log, sizeof log, "%s/.cache/waybar.log", h);
	n_los((char *const[]){ "waybar", NULL }, log);
	/* 3. am Netzteil: Betterbird/Steam im Hintergrund (eigenes Programm, entscheidet selbst) */
	snprintf(ns, sizeof ns, "%s/.local/bin/netz-autostart", h);
	if (access(ns, X_OK) == 0) n_los((char *const[]){ ns, NULL }, NULL);
#if PATCH_TON
	/* 4. EQ für die HDMI-Lautsprecher, falls PulseAudio beim Anstecken der eGPU noch nicht lief */
	n_los((char *const[]){ "hopd", "hdmi-eq", "an", NULL }, NULL);
#endif
	return 0;
}

static int schein_aus(int argc, char **argv)
{
	if (!n_laeuft("hyprlock")) n_los((char *const[]){ "hyprlock", "--no-fade-in", NULL }, NULL);
	schlaf(0.7);
	STARTE("niri", "msg", "action", "power-off-monitors");
	/* geweckt: hyprlock zeigt die Passworteingabe, nach 3 s ohne Eingabe wieder aus */
	pid_t idle = n_los((char *const[]){ "swayidle", "timeout", "3", "niri msg action power-off-monitors", NULL }, NULL);
	if (trocken) return 0;
	while (n_laeuft("hyprlock")) schlaf(1);
	if (idle > 0) kill(-idle, SIGTERM);
	return 0;
}

/* ---------- Deckel im Dienst ---------- */
static int d_fd = -1, d_zu = -1;
static double d_wecken;
static void d_panel(int an)
{
	meld("Deckel %s → %s %s", an ? "auf" : "zu", niri_panel, an ? "an" : "aus");
	in_niri((char *const[]){ "niri", "msg", "output", (char *)niri_panel, an ? "on" : "off", NULL });
}
static void niri_dstart(void)
{
	unsigned long sw[(SW_MAX + 8 * sizeof(long)) / (8 * sizeof(long))];
	JEDES(e, "/dev/input/event*") {
		if (d_fd >= 0) continue;
		int fd = open(e, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
		if (fd < 0) continue;
		memset(sw, 0, sizeof sw);
		if (ioctl(fd, EVIOCGBIT(EV_SW, sizeof sw), sw) >= 0 && (sw[0] & (1UL << SW_LID))) {
			unsigned long st[sizeof sw / sizeof *sw] = { 0 };
			ioctl(fd, EVIOCGSW(sizeof st), st);
			d_fd = fd; d_zu = !!(st[0] & (1UL << SW_LID));
			meld("Deckelschalter: %s (%s)", e, d_zu ? "zu" : "auf");
		} else close(fd);
	}
}
static int niri_dfd(void) { return d_fd; }
static void niri_dlesbar(void)
{
	struct input_event ev[16]; ssize_t n;
	while ((n = read(d_fd, ev, sizeof ev)) > 0)
		for (size_t i = 0; i < (size_t)n / sizeof *ev; i++)
			if (ev[i].type == EV_SW && ev[i].code == SW_LID && ev[i].value != d_zu) { d_zu = ev[i].value; d_panel(!d_zu); }
}
static void niri_duevent(const char *a, const char *s, const char *pfad)
{
	/* Monitor meldet sich neu an (HDMI) → niri schaltet das Panel evtl. wieder ein → gleich nachsehen */
	if (d_zu == 1 && !strcmp(s, "drm") && !strcmp(a, "change")) d_wecken = jetzt() + 1.5;
}
static double niri_dtick(double t)
{
	static int erst = 1;
	if (erst) { erst = 0; return 3600; }
	if (d_zu == 1) in_niri((char *const[]){ "niri", "msg", "output", (char *)niri_panel, "off", NULL });
	return 3600;
}

static struct patch p_niri = { .name = "niri", .start = niri_dstart, .uevent = niri_duevent, .tick = niri_dtick,
	.fd = niri_dfd, .lesbar = niri_dlesbar, .wecken = &d_wecken };
#define NIRI_BEFEHLE \
	{ "niri-start", niri_start, "niri starten (tty1), Neustart mit GPU-Wahl" }, \
	{ "gpu-wahl",   gpu_wahl,   "eGPU/Intel wählen → ~/.config/niri/gpu.kdl" }, \
	{ "sitzung",    sitzung,    "Sitzungsstart: Panel, waybar, netz-autostart" }, \
	{ "schein-aus", schein_aus, "sperren + Bildschirme aus" },
