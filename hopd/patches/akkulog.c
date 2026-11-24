/* Patch akkulog – auf Akku alle 2 min Verbrauch + aktive Programme mitschreiben (im Dienst,
 * kein Timer, kein Python, kein Schnappschuss auf Platte). Format wie das alte akku-log,
 * die alte Datei ~/.local/state/akku-log/log.tsv kann man einfach anhängen.
 *   hopd akku-log [report] [TAGE]   Auswertung (Symlink akku-log) */

static struct pz a_alt[4096];
static int a_nalt = -1;
static double a_talt;

static const char *a_akku(char *b, size_t n)
{
	char p[300], t[32];
	b[0] = 0;
	JEDES(d, "/sys/class/power_supply/*") {
		snprintf(p, sizeof p, "%s/type", d);
		if (!*b && lies(p, t, sizeof t) > 0 && !strcmp(t, "Battery")) snprintf(b, n, "%s", d);
	}
	return *b ? b : NULL;
}

static double akkulog_tick(double t)
{
	char bat[256], p[300], z[1024] = "", zeit[32];
	static struct pz neu[4096]; struct verbr v[64];
	if (am_netz() || !a_akku(bat, sizeof bat)) { a_nalt = -1; return akkulog_takt; } /* am Netz: neu anfangen */
	int nn = prozesse(neu, 4096);
	if (a_nalt >= 0 && t - a_talt < 1800) {
		int k = verbrauch(a_alt, a_nalt, neu, nn, t - a_talt, v, 64);
		size_t o = 0;
		for (int i = 0; i < k && i < 5 && v[i].pct >= 0.5; i++) o += snprintf(z + o, sizeof z - o, "%s%s:%.1f", i ? "," : "", v[i].name, v[i].pct);
	}
	memcpy(a_alt, neu, nn * sizeof *neu); a_nalt = nn; a_talt = t;

	snprintf(p, sizeof p, "%s/power_now", bat);
	double w = lies_zahl(p, -1) / 1e6;
	if (w < 0) {
		char q[300]; snprintf(p, sizeof p, "%s/voltage_now", bat); snprintf(q, sizeof q, "%s/current_now", bat);
		w = lies_zahl(p, 0) / 1e6 * lies_zahl(q, 0) / 1e6;
	}
	long hell = -1;
	JEDES(d, "/sys/class/backlight/*") if (hell < 0) {
		snprintf(p, sizeof p, "%s/max_brightness", d); long m = lies_zahl(p, 0);
		snprintf(p, sizeof p, "%s/brightness", d);
		if (m) hell = (lies_zahl(p, 0) * 100 + m / 2) / m;
	}
	const char *hz = "";
#if PATCH_STROM
	if (strom_zustand >= 0 && strchr(strom_modus[strom_zustand], '@')) hz = strchr(strom_modus[strom_zustand], '@') + 1;
#endif
	time_t jt = time(NULL); strftime(zeit, sizeof zeit, "%Y-%m-%d %H:%M:%S", localtime(&jt));
	snprintf(p, sizeof p, "%s/capacity", bat);
	if (trocken) { meld("  akku-log: %s %ld %% %.1f W [%s]", zeit, lies_zahl(p, 0), w, z); return akkulog_takt; }
	mkdir("/var/lib/hopd", 0755);
	int neu_datei = !da(akkulog_datei);
	FILE *f = fopen(akkulog_datei, "a");
	if (f) {
		if (neu_datei) fputs("zeit\tprozent\twatt\thelligkeit\thz\tegpu\ttop_cpu\n", f);
		fprintf(f, "%s\t%ld\t%.1f\t%ld\t%s\t%d\t%s\n", zeit, lies_zahl(p, 0), w, hell, hz, da("/sys/module/nvidia"), z);
		fclose(f);
	}
	return akkulog_takt;
}

/* ---- Auswertung ---- */
struct a_zeile { time_t t; int pct; double w; int egpu; char apps[256]; };
struct a_app { char name[16]; double summe; int n; };
static int a_nach_w(const void *x, const void *y)
{
	const struct a_app *a = x, *b = y; double p = a->summe / a->n, q = b->summe / b->n;
	return (p < q) - (p > q);
}
static int akkulog_befehl(int argc, char **argv)
{
	int tage = 7;
	if (argc > 1 && strcmp(argv[1], "report")) { if (!isdigit((unsigned char)argv[1][0])) stirb("akku-log [report] [TAGE]"); tage = atoi(argv[1]); }
	if (argc > 2) tage = atoi(argv[2]);
	FILE *f = fopen(akkulog_datei, "r");
	if (!f) { puts("Noch keine Daten (wird nur auf Akku geloggt)."); return 0; }
	static struct a_zeile r[60000]; static struct a_app ap[2048];
	int n = 0, na = 0; char l[1024]; time_t ab = time(NULL) - tage * 86400L;
	if (!fgets(l, sizeof l, f)) l[0] = 0;
	while (n < (int)LEN(r) && fgets(l, sizeof l, f)) {
		struct tm tm = { 0 }; char *s = strptime(l, "%Y-%m-%d %H:%M:%S", &tm), *c[6];
		if (!s) continue;
		tm.tm_isdst = -1; r[n].t = mktime(&tm);
		if (r[n].t < ab) continue;
		l[strcspn(l, "\n")] = 0;
		c[0] = strchr(s, '\t');
		for (int i = 1; i < 6 && c[i - 1]; i++) c[i] = strchr(c[i - 1] + 1, '\t');
		if (!c[5]) continue;
		r[n].pct = atoi(c[0] + 1); r[n].w = atof(c[1] + 1); r[n].egpu = c[4][1] == '1';
		snprintf(r[n].apps, sizeof r[n].apps, "%s", c[5] + 1);
		n++;
	}
	fclose(f);
	if (!n) { printf("Keine Akku-Messungen in den letzten %d Tagen.\n", tage); return 0; }
	double sum = 0; for (int i = 0; i < n; i++) sum += r[i].w;
	double avg = sum / n, wh = 0; char bat[256], p[300];
	if (a_akku(bat, sizeof bat)) { snprintf(p, sizeof p, "%s/energy_full", bat); wh = lies_zahl(p, 0) / 1e6; }
	if (wh <= 0) wh = 70;
	printf("Messungen: %d (≈ %.1f h auf Akku), letzte %d Tage\n", n, n * akkulog_takt / 3600.0, tage);
	printf("Ø Verbrauch: %.1f W  → bei %.0f Wh ≈ %.1f h Laufzeit\n\nSitzungen:\n", avg, wh, avg ? wh / avg : 0);
	for (int a = 0, b; a < n; a = b) { /* Sitzung = Messungen mit < 15 min Abstand */
		double s = 0; int eg = 0; struct a_app top[64]; int nt = 0;
		for (b = a; b < n && (b == a || r[b].t - r[b - 1].t < 900); b++) {
			s += r[b].w; eg |= r[b].egpu;
			for (char *x = r[b].apps, *e; *x; x = *e ? e + 1 : e) {
				e = x + strcspn(x, ","); char *dp = memrchr(x, ':', e - x); if (!dp) break;
				int j; for (j = 0; j < nt && strncmp(top[j].name, x, dp - x); j++);
				if (j == nt && nt < 64) { snprintf(top[nt].name, sizeof top[nt].name, "%.*s", (int)(dp - x), x); top[nt].summe = 0; top[nt++].n = 1; }
				if (j < nt) top[j].summe += atof(dp + 1);
			}
		}
		for (int i = 0; i < nt; i++) top[i].n = 1;
		qsort(top, nt, sizeof *top, a_nach_w);
		char v[32], bis[8]; strftime(v, sizeof v, "%a %d.%m %H:%M", localtime(&r[a].t)); strftime(bis, sizeof bis, "%H:%M", localtime(&r[b - 1].t));
		printf("  %s–%s  Ø %4.1f W  %d→%d %%%s  [", v, bis, s / (b - a), r[a].pct, r[b - 1].pct, eg ? "  eGPU-Treiber geladen" : "");
		for (int i = 0; i < nt && i < 3; i++) printf("%s%s", i ? ", " : "", top[i].name);
		puts("]");
	}
	for (int i = 0; i < n; i++) /* je Programm: Ø Verbrauch, wenn es unter den Top-5 war */
		for (char *x = r[i].apps, *e; *x; x = *e ? e + 1 : e) {
			e = x + strcspn(x, ","); char *dp = memrchr(x, ':', e - x); if (!dp) break;
			int j; for (j = 0; j < na && strncmp(ap[j].name, x, dp - x); j++);
			if (j == na && na < (int)LEN(ap)) { snprintf(ap[na].name, sizeof ap[na].name, "%.*s", (int)(dp - x), x); ap[na].summe = 0; ap[na++].n = 0; }
			if (j < na) { ap[j].summe += r[i].w; ap[j].n++; }
		}
	qsort(ap, na, sizeof *ap, a_nach_w);
	puts("\nVerbrauch, wenn ein Programm unter den Top-CPU-Verbrauchern war (≥3 Messungen):");
	for (int j = 0; j < na; j++) if (ap[j].n >= 3)
		printf("  %-20s Ø %4.1f W  (%d×, %+.1f W ggü. Schnitt)\n", ap[j].name, ap[j].summe / ap[j].n, ap[j].n, ap[j].summe / ap[j].n - avg);
	int ne = 0; double se = 0;
	for (int i = 0; i < n; i++) if (r[i].egpu) { ne++; se += r[i].w; }
	if (ne) printf("\neGPU-Treiber geladen: Ø %.1f W (%d Messungen)\n", se / ne, ne);
	return 0;
}

static struct patch p_akkulog = { .name = "akkulog", .tick = akkulog_tick };
#define AKKULOG_BEFEHLE { "akku-log", akkulog_befehl, "Akku-Auswertung: [report] [TAGE]" },
