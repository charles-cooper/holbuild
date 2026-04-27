HOLDIR ?= $(HOLBUILD_HOLDIR)
POLYC ?= polyc

.PHONY: all test clean

all: bin/holbuild

bin/holbuild: sml/holbuild-script.sml sml/project.sml sml/source_index.sml sml/dependencies.sml sml/build_plan.sml sml/toolchain.sml sml/build_exec.sml sml/cache.sml sml/commands.sml
	@test -n "$(HOLDIR)" || (echo "Set HOLDIR=/path/to/HOL or HOLBUILD_HOLDIR" >&2; exit 1)
	@mkdir -p bin
	HOLBUILD_HOLDIR="$(HOLDIR)" $(POLYC) -o $@ sml/holbuild-script.sml

test: bin/holbuild
	HOLDIR="$(HOLDIR)" tests/run.sh

clean:
	rm -f bin/holbuild
	rmdir bin 2>/dev/null || true
