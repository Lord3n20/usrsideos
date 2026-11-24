/* Patch strom – Netz/Akku-Profile in einem Rutsch, ausgelöst vom Kernel-uevent.
 * Ersetzt: TLP (nur die Teile, die hier etwas bringen), akku-limit, bat.sh (sudo-Aufrufe),
 * den systemd-Sleep-Hook und `light`. WLAN-Stromsparen regelt iwd (main.conf, von hop).
 *   hopd strom [netz|akku|egpu|auto]   (Symlink akku-limit: ac|bat|auto wie früher) */

enum { NETZ, AKKU, AKKU_EGPU };
static const char *strom_namen[] = { "Netz", "Akku", "Akku mit eGPU" };
static int strom_zustand = -1;

static int in_liste(const char *s, const char *const *l)
{
	for (; *l; l++) if (!strcmp(s, *l)) return 1;
	return 0;
}

static void strom_usb(void)
{
	char p[300], v[8], pr[8], id[16], k[8];
	JEDES(d, "/sys/bus/usb/devices/*") {
		snprintf(p, sizeof p, "%s/idVendor", d);
		if (lies(p, v, sizeof v) <= 0) continue;
		snprintf(p, sizeof p, "%s/idProduct", d); lies(p, pr, sizeof pr);
		snprintf(id, sizeof id, "%s:%s", v, pr);
		int an = !in_liste(id, strom_usb_aus);
		/* Eingabegeräte (03), Audio (01), Drucker (07) nie schlafen legen */
		char m[320]; snprintf(m, sizeof m, "%s/*:*/bInterfaceClass", d);
		JEDES(c, m) if (lies(c, k, sizeof k) > 0 && (!strcmp(k, "03") || !strcmp(k, "01") || !strcmp(k, "07"))) an = 0;
		snprintf(p, sizeof p, "%s/power/control", d);
		schreib(p, an ? "auto" : "on");
	}
}

static void strom_rpm(void)
{
	char p[300], t[64];
	JEDES(d, "/sys/bus/pci/devices/*") {
		snprintf(p, sizeof p, "%s/power/control", d);
		schreib(p, in_liste(treiber(d, t, sizeof t), strom_rpm_aus) ? "on" : "auto");
	}
}

static void strom_kerne(const char *cpus /* "" = alle */)
{
	char alle[64], liste[64], maske[300], p[64];
	lies("/sys/devices/system/cpu/present", alle, sizeof alle);
	snprintf(liste, sizeof liste, "%s", *cpus ? cpus : alle);
	cpumaske(liste, maske, sizeof maske);
	schreib("/sys/devices/virtual/workqueue/cpumask", maske);
	schreib("/proc/irq/default_smp_affinity", maske);
	JEDES(d, "/proc/irq/[0-9]*") { snprintf(p, sizeof p, "%s/smp_affinity_list", d); if (!trocken) schreib(p, liste); }
	if (da("/run/systemd/system")) { /* systemd verwaltet die cgroups → über systemd setzen */
		char a[80]; snprintf(a, sizeof a, "AllowedCPUs=%s", cpus);
		const char *u[] = { "user.slice", "system.slice", "init.scope" };
		for (size_t i = 0; i < LEN(u); i++) STARTE("systemctl", "set-property", "--runtime", (char *)u[i], a);
	} else { /* OpenRC/runit: cgroup v2 direkt, Prozesse in der Wurzel per Affinität */
		schreib("/sys/fs/cgroup/cgroup.subtree_control", "+cpuset");
		JEDES(d, "/sys/fs/cgroup/*/cpuset.cpus") schreib(d, *cpus ? cpus : "\n");
		cpu_set_t s; CPU_ZERO(&s);
		for (const char *c = liste; *c;) {
			char *e; long a = strtol(c, &e, 10), b = a;
			if (*e == '-') b = strtol(e + 1, &e, 10);
			for (long i = a; i <= b; i++) CPU_SET(i, &s);
			c = *e == ',' ? e + 1 : e; if (e == c && *c) break;
		}
		FILE *f = fopen("/sys/fs/cgroup/cgroup.procs", "r"); int pid;
		while (f && fscanf(f, "%d", &pid) == 1) if (!trocken) sched_setaffinity(pid, sizeof s, &s);
		if (f) fclose(f);
	}
}

/* RAPL-Grenzen setzen. Die EC-Firmware setzt sie beim Wechsel des Leistungsprofils
 * (luefter, ioctl 0x18) wieder auf 90 W → luefter ruft das danach mit pruefen=1 erneut auf. */
static void strom_rapl(int z, int pruefen)
{
	static const char *pl[2] = { "/sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw",
	                             "/sys/class/powercap/intel-rapl:0/constraint_1_power_limit_uw" };
	long soll[2] = { strom_pl1[z] * 1000000L, strom_pl2[z] * 1000000L };
	for (int i = 0; i < 2; i++) {
		long ist = lies_zahl(pl[i], -1);
		if (pruefen && ist == soll[i]) continue;
		if (pruefen) meld("RAPL PL%d %ld W → %ld W (von Firmware zurückgesetzt)", i + 1, ist / 1000000, soll[i] / 1000000);
		schreibf(pl[i], "%ld", soll[i]);
	}
}

static void strom_anwenden(int z)
{
	char p[300], b[256];
	meld("Profil: %s", strom_namen[z]);
	/* 1. alle Kerne an (sonst behalten abgeschaltete die alte EPP) */
	JEDES(d, "/sys/devices/system/cpu/cpu[1-9]*/online") if (lies_zahl(d, 1) == 0) schreib(d, "1");
	/* 2. RAPL */
	strom_rapl(z, 0);
	/* 3. CPU: Regler, EPP, Turbo, Höchstleistung */
	JEDES(d, "/sys/devices/system/cpu/cpu[0-9]*/cpufreq") {
		snprintf(p, sizeof p, "%s/scaling_available_governors", d);
		if (lies(p, b, sizeof b) > 0 && strstr(b, "powersave")) { snprintf(p, sizeof p, "%s/scaling_governor", d); schreib(p, "powersave"); }
		snprintf(p, sizeof p, "%s/energy_performance_preference", d); schreib(p, strom_epp[z]);
	}
	if (da("/sys/devices/system/cpu/intel_pstate/no_turbo")) {
		schreibf("/sys/devices/system/cpu/intel_pstate/max_perf_pct", "%d", strom_maxperf[z]);
		schreib("/sys/devices/system/cpu/intel_pstate/no_turbo", strom_turbo[z] ? "0" : "1");
		schreib("/sys/devices/system/cpu/intel_pstate/hwp_dynamic_boost", strom_turbo[z] ? "1" : "0");
	} else schreib("/sys/devices/system/cpu/cpufreq/boost", strom_turbo[z] ? "1" : "0");
	if (lies("/sys/firmware/acpi/platform_profile_choices", b, sizeof b) > 0 && strstr(b, strom_profil[z]))
		schreib("/sys/firmware/acpi/platform_profile", strom_profil[z]);
	/* 4. Kerne: auf Akku nur E-Kerne (aus der Topologie, nicht fest verdrahtet) */
	char e[64] = "";
	if (strom_nur_e[z]) lies("/sys/devices/cpu_atom/cpus", e, sizeof e);
	strom_kerne(e);
	/* 5. Geräte */
	schreib("/sys/module/pcie_aspm/parameters/policy", strom_aspm[z]);
	strom_rpm(); strom_usb();
	schreib("/sys/module/snd_hda_intel/parameters/power_save", "1");
	schreibf("/proc/sys/vm/dirty_writeback_centisecs", "%d", strom_writeback[z]);
	if (strom_bt_aus[z]) {
		int verbunden = 0;
		JEDES(c, "/sys/class/bluetooth/hci*:*") { (void)c; verbunden = 1; }
		if (!verbunden) JEDES(r, "/sys/class/rfkill/rfkill*") {
			snprintf(p, sizeof p, "%s/type", r);
			if (lies(p, b, sizeof b) > 0 && !strcmp(b, "bluetooth")) { snprintf(p, sizeof p, "%s/soft", r); schreib(p, "1"); }
		}
	}
	/* 6. Helligkeit direkt in sysfs (kein light/sudo) */
	int erst = strom_hell[z] >= 0;
	JEDES(d, "/sys/class/backlight/*") if (erst) { /* nur das erste (eingebaute) Panel */
		snprintf(p, sizeof p, "%s/max_brightness", d);
		long m = lies_zahl(p, 0), w = m * strom_hell[z] / 100;
		snprintf(p, sizeof p, "%s/brightness", d);
		if (m) schreibf(p, "%ld", w < 1 ? 1 : w);
		erst = 0;
	}
	/* 7. Bildwiederholrate in niri, Waybar-Akkuanzeige auffrischen */
	if (*strom_modus[z]) in_niri((char *const[]){ "niri", "msg", "output", (char *)strom_panel, "mode", (char *)strom_modus[z], NULL });
	signal_an("waybar", SIGRTMIN + 10);
	strom_zustand = z;
}

static void strom_netz(int ac) { strom_anwenden(ac ? NETZ : egpu_da() ? AKKU_EGPU : AKKU); }
static void strom_uevent(const char *a, const char *s, const char *pfad)
{
	(void)pfad;
	if (strcmp(a, "add")) return;
	if (!strcmp(s, "usb")) strom_usb();          /* neues Gerät: gleich richtig einstellen */
	else if (!strcmp(s, "pci")) {               /* eGPU dazu → Akku-Profil lockern */
		strom_rpm();
		if (strom_zustand == AKKU && egpu_da()) strom_anwenden(AKKU_EGPU);
	}
}

static int strom_befehl(int argc, char **argv)
{
	const char *m = argc > 1 ? argv[1] : "auto";
	if (geteuid() && !trocken) stirb("braucht root");
	if (!strcmp(m, "netz") || !strcmp(m, "ac")) strom_anwenden(NETZ);
	else if (!strcmp(m, "akku") || !strcmp(m, "bat")) strom_anwenden(AKKU);
	else if (!strcmp(m, "egpu")) strom_anwenden(AKKU_EGPU);
	else if (!strcmp(m, "auto")) strom_netz(am_netz());
	else stirb("%s netz|akku|egpu|auto", argv[0]);
	return 0;
}

static struct patch p_strom = { .name = "strom", .netz = strom_netz, .uevent = strom_uevent };
#define STROM_BEFEHLE \
	{ "strom", strom_befehl, "Profil von Hand: netz|akku|egpu|auto" }, \
	{ "akku-limit", strom_befehl, "alter Name für strom (ac|bat|auto)" },
