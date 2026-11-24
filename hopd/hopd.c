/* hopd – ein einziges Programm für alle Rechner-Optimierungen, im Stil von dwm:
 * Kern klein, jede Funktion ist ein Patch (patches/<name>.c). Welche Patches im Binary
 * landen, steht in patches.h (schreibt hop), alle Werte in config.h (wie dwm: von Hand
 * anpassen, neu bauen). Nicht eingebaute Patches kosten kein Byte.
 *
 *   hopd dienst              Daemon (root): Netzteil-, Kernel- und Gerätemeldungen per
 *                            Netlink/kmsg, keine Abfrage-Schleifen, kein udev nötig
 *   hopd befehle             eingebaute Befehle; Symlinks (luefter, wg-tunnel …) rufen sie direkt
 *   HOPD_TROCKEN=1 hopd …    nichts schreiben, nur anzeigen, was passieren würde
 */
#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <grp.h>
#include <linux/netlink.h>
#include <poll.h>
#include <pwd.h>
#include <sched.h>
#include <signal.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "patches.h"
#include "config.h"

#define LEN(a) (sizeof(a) / sizeof((a)[0]))

struct patch {
	const char *name;
	void (*start)(void);                    /* einmal beim Dienststart */
	void (*netz)(int ac);                   /* Netzteil an/ab, Start, nach Standby */
	double (*tick)(double t);               /* gibt Sekunden bis zum nächsten Aufruf zurück */
	void (*uevent)(const char *aktion, const char *subsys, const char *pfad);
	void (*kmsg)(const char *zeile);
	void (*ende)(void);
	int (*fd)(void);                        /* eigene Datei zum Mitlesen (z. B. Deckelschalter), -1 = keine */
	void (*lesbar)(void);
	double *wecken;                         /* Patch setzt *wecken = Zeitpunkt → tick kommt spätestens dann */
};
struct befehl { const char *name; int (*fn)(int argc, char **argv); const char *hilfe; };

static int trocken;
static volatile sig_atomic_t schluss;

/* ---------- kleine Helfer, von allen Patches benutzt ---------- */
static void meld(const char *fmt, ...)
{
	va_list ap; va_start(ap, fmt); vfprintf(stdout, fmt, ap); va_end(ap);
	fputc('\n', stdout); fflush(stdout);
}
static void stirb(const char *fmt, ...)
{
	va_list ap; va_start(ap, fmt); fputs("hopd: ", stderr); vfprintf(stderr, fmt, ap); va_end(ap);
	fputc('\n', stderr); exit(1);
}
static int lies(const char *p, char *b, size_t n)
{
	int fd = open(p, O_RDONLY | O_CLOEXEC); ssize_t r;
	if (fd < 0) { if (n) b[0] = 0; return -1; }
	r = read(fd, b, n - 1); close(fd);
	if (r < 0) r = 0;
	while (r > 0 && (b[r - 1] == '\n' || b[r - 1] == ' ')) r--;
	b[r] = 0;
	return (int)r;
}
static long lies_zahl(const char *p, long d)
{
	char b[32];
	return lies(p, b, sizeof b) > 0 ? strtol(b, NULL, 0) : d;
}
static int da(const char *p) { return access(p, F_OK) == 0; }
/* sysfs-Auswahllisten wie "[default] performance": gewählt ist der Wert in Klammern */
static int klammer_gleich(const char *ist, const char *s)
{
	const char *a = strchr(ist, '['), *e = a ? strchr(a, ']') : NULL;
	return a && e && (size_t)(e - a - 1) == strlen(s) && !strncmp(a + 1, s, e - a - 1);
}
static int schreib(const char *p, const char *s)
{
	int fd, r; char ist[256];
	/* gleicher Wert steht schon drin → nichts tun (weniger sysfs-Arbeit, ruhige Trocken-Ausgabe) */
	if (strncmp(p, "/sys/kernel/debug", 17) && lies(p, ist, sizeof ist) >= 0 && (!strcmp(ist, s) || klammer_gleich(ist, s))) return 0;
	if (trocken) { meld("  schreibe %s ← %s", p, s); return 0; }
	if ((fd = open(p, O_WRONLY | O_CLOEXEC)) < 0) return -1;
	r = write(fd, s, strlen(s)) < 0 ? -1 : 0;
	close(fd);
	return r;
}
static int schreibf(const char *p, const char *fmt, ...)
{
	char b[512]; va_list ap;
	va_start(ap, fmt); vsnprintf(b, sizeof b, fmt, ap); va_end(ap);
	return schreib(p, b);
}
/* Datei (nicht sysfs) atomar ersetzen */
static void datei_ersetzen(const char *p, const char *s, mode_t m)
{
	char t[512]; int fd;
	if (trocken) { meld("  datei %s ← %s", p, s); return; }
	snprintf(t, sizeof t, "%s.neu", p);
	if ((fd = open(t, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, m)) < 0) return;
	if (write(fd, s, strlen(s)) < 0) {}
	fchmod(fd, m); close(fd); rename(t, p);
}
static double uhr(clockid_t c) { struct timespec ts; clock_gettime(c, &ts); return ts.tv_sec + ts.tv_nsec / 1e9; }
static double jetzt(void) { return uhr(CLOCK_MONOTONIC); }
static void schlaf(double s) { struct timespec ts = { (time_t)s, (long)((s - (time_t)s) * 1e9) }; nanosleep(&ts, NULL); }

/* Programm starten und warten (selten: Netzteilwechsel, Tunnel). Gibt den Exit-Code zurück. */
static int starte(char *const argv[])
{
	pid_t p; int st;
	if (trocken) {
		fputs("  starte", stdout);
		for (int i = 0; argv[i]; i++) printf(" %s", argv[i]);
		meld("");
		return 0;
	}
	if ((p = fork()) == 0) {
		int n = open("/dev/null", O_RDWR); dup2(n, 0); dup2(n, 1);
		execvp(argv[0], argv); _exit(127);
	}
	if (p < 0 || waitpid(p, &st, 0) < 0) return -1;
	return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}
#define STARTE(...) starte((char *const[]){ __VA_ARGS__, NULL })

/* über alle Treffer eines glob-Musters laufen */
#define JEDES(var, muster) \
	for (glob_t _g = { 0 }, *_gp = glob(muster, 0, NULL, &_g) == 0 ? &_g : (globfree(&_g), (glob_t *)NULL); _gp; globfree(_gp), _gp = NULL) \
		for (size_t _i = 0; _i < _gp->gl_pathc; _i++) \
			for (const char *var = _gp->gl_pathv[_i]; var; var = NULL)

static int am_netz(void)
{
	char t[32], p[300]; int mains = 0;
	JEDES(d, "/sys/class/power_supply/*") {
		snprintf(p, sizeof p, "%s/type", d);
		if (lies(p, t, sizeof t) > 0 && !strcmp(t, "Mains")) {
			mains = 1;
			snprintf(p, sizeof p, "%s/online", d);
			if (lies_zahl(p, 0) == 1) return 1;
		}
	}
	return !mains; /* ohne Netzteil-Eintrag (Desktop) gilt: am Netz */
}
static int pci_hersteller(const char *v)
{
	char b[16];
	JEDES(p, "/sys/bus/pci/devices/*/vendor")
		if (lies(p, b, sizeof b) > 0 && !strcmp(b, v)) return 1;
	return 0;
}
static int egpu_da(void) { return pci_hersteller("0x10de"); }
static const char *treiber(const char *geraet, char *b, size_t n)
{
	char p[300], z[300]; ssize_t r;
	snprintf(p, sizeof p, "%s/driver", geraet);
	if ((r = readlink(p, z, sizeof z - 1)) < 0) { b[0] = 0; return b; }
	z[r] = 0;
	snprintf(b, n, "%s", strrchr(z, '/') ? strrchr(z, '/') + 1 : z);
	return b;
}
/* Prozesse namens n ein Signal schicken (z. B. waybar neu zeichnen lassen) */
static void signal_an(const char *n, int sig)
{
	char p[64], c[32]; DIR *d = opendir("/proc"); struct dirent *e;
	if (!d) return;
	while ((e = readdir(d)))
		if (isdigit((unsigned char)e->d_name[0])) {
			snprintf(p, sizeof p, "/proc/%s/comm", e->d_name);
			if (lies(p, c, sizeof c) > 0 && !strcmp(c, n)) {
				if (trocken) meld("  signal %d → %s (%s)", sig, n, e->d_name);
				else kill(atoi(e->d_name), sig);
			}
		}
	closedir(d);
}
/* Befehl in der niri-Sitzung des Nutzers ausführen (niri msg …), ohne sudo/Skript */
static void in_niri(char *const argv[])
{
	struct stat st;
	JEDES(s, "/run/user/*/niri.*.sock") {
		if (stat(s, &st)) continue;
		if (trocken) { printf("  als uid %u:", st.st_uid); starte(argv); continue; }
		pid_t p = fork();
		if (p == 0) {
			struct passwd *pw = getpwuid(st.st_uid);
			char rt[64]; snprintf(rt, sizeof rt, "/run/user/%u", st.st_uid);
			if (!pw || initgroups(pw->pw_name, pw->pw_gid) || setgid(pw->pw_gid) || setuid(st.st_uid)) _exit(1);
			setenv("NIRI_SOCKET", s, 1); setenv("XDG_RUNTIME_DIR", rt, 1);
			int n = open("/dev/null", O_RDWR); dup2(n, 0); dup2(n, 1); dup2(n, 2);
			execvp(argv[0], argv); _exit(127);
		}
		if (p > 0) waitpid(p, NULL, 0);
	}
}

/* CPU-Liste "12-21,24" → Kernel-Maske "3ff000" (beliebig viele CPUs, 32-Bit-Gruppen) */
static void cpumaske(const char *liste, char *aus, size_t n)
{
	uint32_t w[32] = { 0 }; int hoch = 0; const char *s = liste;
	while (*s) {
		char *e; long a = strtol(s, &e, 10), b = a;
		if (e == s) break;
		if (*e == '-') b = strtol(e + 1, &e, 10);
		for (long c = a; c <= b && c < 1024; c++) { w[c / 32] |= 1u << (c % 32); if (c / 32 > hoch) hoch = c / 32; }
		s = *e == ',' ? e + 1 : e;
	}
	size_t o = 0;
	for (int i = hoch; i >= 0; i--)
		o += snprintf(aus + o, n - o, i == hoch ? "%x" : ",%08x", w[i]);
}

/* Schnappschuss der CPU-Zeit aller Prozesse (für „wer verbraucht gerade?“) */
struct pz { int pid; unsigned long long t; char name[16]; };
static int prozesse(struct pz *a, int max)
{
	char p[64], b[1024]; int n = 0; DIR *d = opendir("/proc"); struct dirent *e;
	if (!d) return 0;
	while ((e = readdir(d)) && n < max) {
		if (!isdigit((unsigned char)e->d_name[0])) continue;
		snprintf(p, sizeof p, "/proc/%s/stat", e->d_name);
		if (lies(p, b, sizeof b) <= 0) continue;
		char *l = strchr(b, '('), *r = strrchr(b, ')');
		if (!l || !r) continue;
		unsigned long long ut = 0, stt = 0;
		/* nach ") " folgen state ppid … ; utime ist Feld 14, stime 15 */
		if (sscanf(r + 2, "%*c %*d %*d %*d %*d %*d %*u %*u %*u %*u %*u %llu %llu", &ut, &stt) != 2) continue;
		a[n].pid = atoi(e->d_name); a[n].t = ut + stt;
		snprintf(a[n].name, sizeof a[n].name, "%.*s", (int)(r - l - 1), l + 1);
		if (!strncmp(a[n].name, "kworker", 7)) strcpy(a[n].name, "kworker");
		n++;
	}
	closedir(d);
	return n;
}
/* Verbrauch je Programmname zwischen zwei Schnappschüssen, absteigend sortiert */
struct verbr { char name[16]; double pct; };
static int nach_pct(const void *a, const void *b)
{
	double x = ((const struct verbr *)a)->pct, y = ((const struct verbr *)b)->pct;
	return (x < y) - (x > y);
}
static int verbrauch(struct pz *alt, int na, struct pz *neu, int nn, double dt, struct verbr *v, int max)
{
	int k = 0; long hz = sysconf(_SC_CLK_TCK);
	for (int i = 0; i < nn; i++) {
		unsigned long long vorher = 0;
		for (int j = 0; j < na; j++) if (alt[j].pid == neu[i].pid) { vorher = alt[j].t; break; }
		if (neu[i].t <= vorher) continue;
		double p = (neu[i].t - vorher) * 100.0 / hz / dt;
		int j; for (j = 0; j < k && strcmp(v[j].name, neu[i].name); j++);
		if (j == k) { if (k == max) continue; strcpy(v[k].name, neu[i].name); v[k++].pct = 0; }
		v[j].pct += p;
	}
	qsort(v, k, sizeof *v, nach_pct);
	return k;
}

static void sd_melden(const char *s)
{
	const char *n = getenv("NOTIFY_SOCKET"); struct sockaddr_un a = { .sun_family = AF_UNIX }; int fd;
	if (!n || !*n) return;
	snprintf(a.sun_path, sizeof a.sun_path, "%s", n);
	if (a.sun_path[0] == '@') a.sun_path[0] = 0;
	if ((fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0)) < 0) return;
	sendto(fd, s, strlen(s), 0, (struct sockaddr *)&a, offsetof(struct sockaddr_un, sun_path) + strlen(n));
	close(fd);
}

/* ---------- Patches ---------- */
#if PATCH_STROM
#include "patches/strom.c"
#endif
#if PATCH_LUEFTER
#include "patches/luefter.c"
#endif
#if PATCH_EGPU
#include "patches/egpu.c"
#endif
#if PATCH_AKKULOG
#include "patches/akkulog.c"
#endif
#if PATCH_WG
#include "patches/wg.c"
#endif
#if PATCH_CHROMIUM
#include "patches/chromium.c"
#endif
#if PATCH_TON
#include "patches/ton.c"
#endif
#if PATCH_NIRI
#include "patches/niri.c"
#endif

static struct patch *patches[] = {
#if PATCH_STROM
	&p_strom,
#endif
#if PATCH_LUEFTER
	&p_luefter,
#endif
#if PATCH_EGPU
	&p_egpu,
#endif
#if PATCH_AKKULOG
	&p_akkulog,
#endif
#if PATCH_WG
	&p_wg,
#endif
#if PATCH_TON
	&p_ton,
#endif
#if PATCH_NIRI
	&p_niri,
#endif
	NULL
};

static int dienst(int argc, char **argv);
static int befehle_zeigen(int argc, char **argv);
static const struct befehl befehle[] = {
	{ "dienst",  dienst,         "Daemon starten (root, vom Init-System)" },
	{ "befehle", befehle_zeigen, "eingebaute Befehle auflisten" },
#if PATCH_STROM
	STROM_BEFEHLE
#endif
#if PATCH_LUEFTER
	LUEFTER_BEFEHLE
#endif
#if PATCH_EGPU
	EGPU_BEFEHLE
#endif
#if PATCH_AKKULOG
	AKKULOG_BEFEHLE
#endif
#if PATCH_WG
	WG_BEFEHLE
#endif
#if PATCH_CHROMIUM
	CHROMIUM_BEFEHLE
#endif
#if PATCH_TON
	TON_BEFEHLE
#endif
#if PATCH_NIRI
	NIRI_BEFEHLE
#endif
};

static int befehle_zeigen(int argc, char **argv)
{
	(void)argv;
	for (size_t i = 0; i < LEN(befehle); i++)
		if (argc > 1) printf("%s\n", befehle[i].name); /* „befehle -k“: nur Namen (für hop) */
		else printf("  %-15s %s\n", befehle[i].name, befehle[i].hilfe);
	if (argc <= 1) {
		fputs("Patches:", stdout);
		for (struct patch **p = patches; *p; p++) printf(" %s", (*p)->name);
		putchar('\n');
	}
	return 0;
}

static void beenden(int s) { (void)s; schluss = 1; }

/* Netlink-uevent: "aktion@pfad\0KEY=WERT\0…" */
static void uevent_lesen(int fd, int *netz)
{
	char b[8192]; ssize_t n;
	while ((n = recv(fd, b, sizeof b - 1, MSG_DONTWAIT)) > 0) {
		const char *akt = "", *sub = "", *pfad = "";
		b[n] = 0;
		for (char *s = b; s < b + n; s += strlen(s) + 1) {
			if (!strncmp(s, "ACTION=", 7)) akt = s + 7;
			else if (!strncmp(s, "SUBSYSTEM=", 10)) sub = s + 10;
			else if (!strncmp(s, "DEVPATH=", 8)) pfad = s + 8;
		}
		if (!strcmp(sub, "power_supply")) {
			int ac = am_netz();
			if (ac != *netz) {
				*netz = ac;
				meld("Netzteil %s", ac ? "angesteckt" : "abgesteckt");
				for (struct patch **p = patches; *p; p++) if ((*p)->netz) (*p)->netz(ac);
			}
		}
		for (struct patch **p = patches; *p; p++) if ((*p)->uevent) (*p)->uevent(akt, sub, pfad);
	}
}

static int dienst(int argc, char **argv)
{
	(void)argc; (void)argv;
	int np = 0, kmsg = -1, ue, netz;
	double naechst[LEN(patches)] = { 0 }, wd = 0, wd_zuletzt = 0;
	struct sigaction sa = { .sa_handler = beenden };
	struct sockaddr_nl nl = { .nl_family = AF_NETLINK, .nl_groups = 1 };

	if (geteuid() && !trocken) stirb("dienst braucht root");
	sigaction(SIGTERM, &sa, NULL); sigaction(SIGINT, &sa, NULL);
	signal(SIGPIPE, SIG_IGN);
	setvbuf(stdout, NULL, _IOLBF, 0);

	if ((ue = socket(AF_NETLINK, SOCK_DGRAM | SOCK_CLOEXEC | SOCK_NONBLOCK, NETLINK_KOBJECT_UEVENT)) < 0
	    || bind(ue, (struct sockaddr *)&nl, sizeof nl) < 0)
		stirb("netlink: %s", strerror(errno));
	for (struct patch **p = patches; *p; p++, np++) if ((*p)->kmsg && kmsg < 0) {
		if ((kmsg = open("/dev/kmsg", O_RDONLY | O_NONBLOCK | O_CLOEXEC)) >= 0) lseek(kmsg, 0, SEEK_END);
	}
	for (struct patch **p = patches; *p; p++) if ((*p)->start) (*p)->start();
	netz = am_netz();
	for (struct patch **p = patches; *p; p++) if ((*p)->netz) (*p)->netz(netz);

	if (getenv("WATCHDOG_USEC")) wd = atof(getenv("WATCHDOG_USEC")) / 2e6;
	double schlaf_versatz = uhr(CLOCK_BOOTTIME) - jetzt();
	sd_melden("READY=1");
	meld("hopd läuft (%d Patches, %s)", np, netz ? "Netz" : "Akku");

	while (!schluss) {
		double t = jetzt(), warte = 10;
		for (int i = 0; i < np; i++) {
			double *w = patches[i]->wecken;
			if (w && *w > 0) { if (*w < naechst[i]) naechst[i] = *w; *w = 0; }
			if (patches[i]->tick && naechst[i] - t < warte) warte = naechst[i] - t;
		}
		if (wd > 0 && wd < warte) warte = wd;
		struct pollfd f[2 + LEN(patches)] = { { ue, POLLIN, 0 }, { kmsg, POLLIN, 0 } };
		int nf = 2, pf[LEN(patches)];
		for (int i = 0; i < np; i++) {
			pf[i] = patches[i]->fd ? patches[i]->fd() : -1;
			if (pf[i] >= 0) { f[nf].fd = pf[i]; f[nf].events = POLLIN; f[nf++].revents = 0; }
		}
		if (poll(f, nf, warte > 0 ? (int)(warte * 1000) + 1 : 0) < 0 && errno != EINTR) break;
		if (schluss) break;
		for (int i = 0, k = 2; i < np; i++) if (pf[i] >= 0) { if (f[k].revents & POLLIN) patches[i]->lesbar(); k++; }

		if (f[0].revents & POLLIN) uevent_lesen(ue, &netz);
		if (kmsg >= 0 && (f[1].revents & POLLIN)) {
			char b[2048]; ssize_t n;
			while ((n = read(kmsg, b, sizeof b - 1)) > 0 || (n < 0 && errno == EPIPE)) {
				if (n <= 0) continue;
				b[n] = 0;
				char *m = strchr(b, ';'), *nl2;
				if (!m) continue;
				if ((nl2 = strchr(++m, '\n'))) *nl2 = 0;
				for (struct patch **p = patches; *p; p++) if ((*p)->kmsg) (*p)->kmsg(m);
			}
		}
		/* Standby erkennen: BOOTTIME läuft im Schlaf weiter, MONOTONIC nicht → kein Sleep-Hook nötig */
		t = jetzt();
		double v = uhr(CLOCK_BOOTTIME) - t;
		if (v - schlaf_versatz > 2) {
			schlaf_versatz = v; netz = am_netz();
			meld("aufgewacht – Einstellungen neu (%s)", netz ? "Netz" : "Akku");
			for (struct patch **p = patches; *p; p++) if ((*p)->netz) (*p)->netz(netz);
		}
		for (int i = 0; i < np; i++)
			if (patches[i]->tick && naechst[i] <= t) naechst[i] = t + patches[i]->tick(t);
		if (wd > 0 && t - wd_zuletzt >= wd) { sd_melden("WATCHDOG=1"); wd_zuletzt = t; }
	}
	for (struct patch **p = patches; *p; p++) if ((*p)->ende) (*p)->ende();
	meld("hopd beendet");
	return 0;
}

int main(int argc, char **argv)
{
	const char *n = strrchr(argv[0], '/') ? strrchr(argv[0], '/') + 1 : argv[0];
	trocken = getenv("HOPD_TROCKEN") && *getenv("HOPD_TROCKEN") == '1';
	if (!strcmp(n, "hopd")) { /* hopd BEFEHL … */
		if (argc < 2) { fputs("Aufruf: hopd BEFEHL …\n", stderr); befehle_zeigen(1, argv); return 2; }
		argc--; argv++; n = argv[0];
	}
	for (size_t i = 0; i < LEN(befehle); i++)
		if (!strcmp(n, befehle[i].name)) return befehle[i].fn(argc, argv);
	fprintf(stderr, "hopd: unbekannter Befehl „%s“ (hopd befehle)\n", n);
	return 2;
}
