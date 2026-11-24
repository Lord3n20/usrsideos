# hopd – wie dwm: config.h und patches.h anpassen, dann `make` und `make install`.
# Ein einziger Übersetzungslauf (alle Patches per #include) → der Compiler sieht alles,
# nicht eingebaute Patches fehlen komplett im Binary.
PREFIX  ?= /usr/local
CC      ?= cc
CFLAGS  ?= -Os -pipe -march=native
CFLAGS  += -std=gnu11 -Wall -Wextra -Wno-unused-function -Wno-unused-parameter -Wno-format-truncation \
           -ffunction-sections -fdata-sections -fno-asynchronous-unwind-tables \
           -fno-plt -fstack-protector-strong -D_FORTIFY_SOURCE=2
LDFLAGS += -Wl,--gc-sections -Wl,-O1 -Wl,--as-needed -Wl,-z,relro,-z,now -s

hopd: hopd.c config.h patches.h patches/*.c
	$(CC) $(CFLAGS) -o $@ hopd.c $(LDFLAGS)

config.h:
	test -f $@ || cp config.def.h $@
patches.h:
	test -f $@ || cp patches.def.h $@

# statisch mit musl (läuft dann auf jeder Distro, auch ohne glibc): make static
static:
	$(MAKE) CC="musl-gcc" LDFLAGS="-static -Wl,--gc-sections -s" hopd

install: hopd
	install -Dm755 hopd $(DESTDIR)$(PREFIX)/bin/hopd
	for b in $$(./hopd befehle -k); do case $$b in dienst|befehle) ;; *) ln -sf hopd $(DESTDIR)$(PREFIX)/bin/$$b ;; esac; done

uninstall:
	for b in $$(./hopd befehle -k 2>/dev/null); do [ -L $(DESTDIR)$(PREFIX)/bin/$$b ] && rm -f $(DESTDIR)$(PREFIX)/bin/$$b; done; true
	rm -f $(DESTDIR)$(PREFIX)/bin/hopd

clean:
	rm -f hopd

.PHONY: static install uninstall clean
