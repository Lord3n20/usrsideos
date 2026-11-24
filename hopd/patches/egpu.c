/* Patch egpu – Thunderbolt-eGPU, die die Firmware nach manchen Kaltstarts nicht verbindet
 * (UCSI GET_CURRENT_CAM = 0xff), per UCSI CONNECTOR_RESET mit Hard-Reset-Bit wecken
 * (= Ab-/Anstecken per Software, live getestet 11.11.2026, eGPU nach ~2 s da).
 * NICHT: ucsi_acpi neu binden (PPM init -ETIMEDOUT) oder NHI neu binden (wirkungslos).
 * Außerdem schreibt der Dienst jeden Verbindungsabriss mit (aus /dev/kmsg, ohne journalctl).
 *   hopd egpu-weck [jetzt]   beim Booten (oneshot-Dienst egpu-weck) bzw. im Betrieb */

#define E_P "/sys/class/typec/port0-partner"
#define E_CMD "/sys/kernel/debug/usb/ucsi/USBC000:00/command"

static double e_up(void) { char b[64]; lies("/proc/uptime", b, sizeof b); return atof(b); }
static int e_geraet(void)
{
	DIR *d = opendir("/sys/bus/thunderbolt/devices"); struct dirent *e; int ja = 0;
	if (!d) return 0;
	while ((e = readdir(d)) && !ja) { /* ^[0-9]+-[1-9]$ */
		const char *s = e->d_name;
		if (!isdigit((unsigned char)*s)) continue;
		while (isdigit((unsigned char)*s)) s++;
		ja = s[0] == '-' && s[1] >= '1' && s[1] <= '9' && !s[2];
	}
	closedir(d);
	return ja;
}
static int e_partner(void)
{
	char b[16];
	JEDES(s, E_P "/*/svid") if (lies(s, b, sizeof b) > 0 && strstr(b, "8087")) return 1;
	return 0;
}
static int e_nvidia(void)
{
	char p[300], t[32];
	JEDES(r, "/sys/class/drm/renderD*") { snprintf(p, sizeof p, "%s/device", r); if (!strcmp(treiber(p, t, sizeof t), "nvidia")) return 1; }
	return 0;
}
static int e_cmd_da(void) { return da(E_CMD); }
static int e_warte(double s, int (*f)(void)) { for (int n = (int)(s * 5); n > 0; n--) { if (f()) return 1; schlaf(0.2); } return f(); }
static int e_fertig(const char *w)
{
	if (e_warte(10, e_nvidia)) meld("%s – NVIDIA-Render-Node da (%.2f s)", w, e_up());
	else meld("%s – aber NVIDIA-Treiber nach 10 s nicht bereit (%.2f s)", w, e_up());
	return 0;
}

static int egpu_weck(int argc, char **argv);
/* Fertig-Marke für gpu-wahl (niri-Patch): ersetzt `systemctl is-active egpu-weck`, geht mit jedem Init */
static int egpu_befehl(int argc, char **argv)
{
	if (geteuid() && !trocken) stirb("braucht root");
	if (!trocken) { mkdir("/run/hopd", 0755); unlink("/run/hopd/egpu-fertig"); close(open("/run/hopd/egpu-laeuft", O_CREAT | O_WRONLY, 0644)); }
	int r = egpu_weck(argc, argv);
	if (!trocken) { rename("/run/hopd/egpu-laeuft", "/run/hopd/egpu-fertig"); }
	return r;
}
static int egpu_weck(int argc, char **argv)
{
	if (argc < 2 || strcmp(argv[1], "jetzt")) {
		/* Boot: UCSI meldet den Partner ≈ 3,5 s nach Kernelstart, das TB-Gerät ≈ 4,3 s, wenn die
		 * Firmware den Tunnel gebaut hat. Mit TB-Partner 1,5 s warten, mit Partner ohne Altmodes
		 * bis 3 s, mit Port ohne Partner 2 s, sonst bis Uptime 12 s – Login nicht aufhalten. */
		double pz = 0, portz = 0, pdz = 0;
		while (!e_geraet()) {
			double t = e_up();
			if (!portz && da("/sys/class/typec/port0")) portz = t;
			if (!pdz && da(E_P)) pdz = t;
			if (!pz && e_partner()) pz = t;
			if (pz) { if (t >= pz + 1.5) break; }
			else if (pdz) { if (t >= pdz + 3) break; }
			else if (portz && t >= portz + 2) break;
			else if (t >= 12) break;
			schlaf(0.1);
		}
		if (e_geraet()) return e_fertig("eGPU von selbst verbunden");
	}
	if (e_geraet()) return e_fertig("eGPU ist schon verbunden");
	if (!e_partner()) { meld("kein Thunderbolt-Partner am Port 0 – nichts zu tun (%.2f s)", e_up()); return 0; }
	if (!da("/sys/kernel/debug/usb")) mount("debugfs", "/sys/kernel/debug", "debugfs", 0, NULL);
	if (!e_warte(5, e_cmd_da)) { meld("UCSI-debugfs fehlt (%s)", E_CMD); return 1; }
	for (int v = 1; v <= egpu_versuche; v++) {
		meld("TB-Partner da, kein TB-Gerät → UCSI Connector-Hard-Reset, Versuch %d/%d (%.2f s)", v, egpu_versuche, e_up());
		if (schreib(E_CMD, "0x810003")) { meld("Befehl abgelehnt"); schlaf(1); continue; }
		if (e_warte(8, e_geraet)) return e_fertig("eGPU nach Reset verbunden");
		if (!e_warte(5, e_partner)) { meld("Type-C-Partner nach Reset verschwunden"); break; }
	}
	meld("eGPU nicht verbunden – bitte ab- und wieder anstecken (%.2f s)", e_up());
	return 1;
}

/* Abriss-Protokoll (früher egpu-abriss-log.sh + User-Dienst) */
static void egpu_kmsg(const char *m)
{
	const char *was = NULL;
	if (strstr(m, "pciehp") && strstr(m, "Link Down")) was = "PCIe-Verbindung abgerissen";
	else if (strstr(m, "GPU has fallen off the bus")) was = "GPU vom Bus gefallen (bis Neustart tot)";
	else if (strstr(m, "thunderbolt") && strstr(m, "device disconnected")) was = "Thunderbolt-Gerät getrennt";
	if (!was) return;
	meld("eGPU: %s", was);
	if (trocken) return;
	char z[32]; time_t t = time(NULL);
	strftime(z, sizeof z, "%d.%m.%Y %H:%M:%S", localtime(&t));
	FILE *f = fopen(egpu_log, "a");
	if (!f) return;
	fprintf(f, "%s  %s\n", z, was); fclose(f);
	struct passwd *pw = getpwnam(nutzer);
	if (pw && chown(egpu_log, pw->pw_uid, pw->pw_gid)) {}
}

static struct patch p_egpu = { .name = "egpu", .kmsg = egpu_kmsg };
#define EGPU_BEFEHLE { "egpu-weck", egpu_befehl, "eGPU verbinden (Boot bzw. „jetzt“)" },
