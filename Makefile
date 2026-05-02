HOLDIR ?= $(HOLBUILD_HOLDIR)
POLYC ?= polyc
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin

.PHONY: all install uninstall test clean

all: bin/holbuild

bin/holbuild: sml/holbuild-script.sml sml/hash.sml sml/project.sml sml/source_index.sml sml/dependencies.sml sml/build_plan.sml sml/toolchain.sml sml/status.sml sml/goalfrag_runtime.sml sml/goalfrag_plan.sml sml/theory_checkpoints.sml sml/checkpoint_store.sml sml/theory_diagnostics.sml sml/build_exec.sml sml/cache.sml sml/commands.sml
	@test -n "$(HOLDIR)" || (echo "Set HOLDIR=/path/to/HOL or HOLBUILD_HOLDIR" >&2; exit 1)
	@mkdir -p bin
	HOLBUILD_HOLDIR="$(HOLDIR)" $(POLYC) -o $@ sml/holbuild-script.sml

install: bin/holbuild
	install -d "$(DESTDIR)$(BINDIR)"
	install -m 755 bin/holbuild "$(DESTDIR)$(BINDIR)/holbuild"

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/holbuild"

test: bin/holbuild
	HOLDIR="$(HOLDIR)" tests/run.sh

clean:
	rm -f bin/holbuild
	rmdir bin 2>/dev/null || true
