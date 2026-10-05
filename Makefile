# lance_fdw — foreign-data wrapper that reads Lance datasets from Apache Cloudberry.
#
#   make                  build liblance_c.so (submodule) and lance_fdw.so
#   make install          install both, plus the control/SQL files
#   make installcheck     run the pg_regress suites against a running cluster
#   make check-syntax     gcc -fsyntax-only over src/*.c; needs no cluster and
#                         no pg_config, only a configured server header tree
#   make clean-lance-c    cargo clean in the submodule (a rebuild costs ~16 min)
#
# lance-c is built from the pinned submodule by default.  To use one that is
# already built or installed somewhere else:
#
#   make LANCE_C_PREFIX=/opt/lance-c                 (expects include/ and lib/)
#   make LANCE_C_INCDIR=... LANCE_C_LIBDIR=...       (override either half)
#   make USE_PKGCONFIG_LANCE_C=1                     (ask pkg-config for lance-c)
#
# The cargo build needs Rust >= 1.91, protoc and access to a crates registry;
# see README.md.  test/gate/gate.sh prepares all of that inside the container.

# check-syntax / check-scripts are defined before PGXS is included, so name the
# default goal explicitly or `make` would run the syntax check instead of building.
.DEFAULT_GOAL := all

MODULE_big = lance_fdw
EXTENSION = lance_fdw
DATA = sql/lance_fdw--0.1.sql
PGFILEDESC = "lance_fdw - foreign-data wrapper for Lance datasets"

OBJS = \
	src/lance_fdw.o \
	src/lance_option.o \
	src/lance_runtime.o \
	src/lance_arrow.o \
	src/lance_dispatch.o \
	src/lance_scan.o \
	src/lance_import.o \
	vendor/nanoarrow/src/nanoarrow.o

# "install" first: it creates the extension and the lance_regress schema every
# other suite builds on.  test/gate/gate.sh keeps the same list.
REGRESS = install ddl import errors_ddl scan_core parallel snapshot explain \
	creds errors_scan
REGRESS_OPTS = --inputdir=test/regress --outputdir=test/regress

# ---------------------------------------------------------------------------
# Where lance-c comes from
# ---------------------------------------------------------------------------

LANCE_C_DIR = third_party/lance-c
CARGO ?= cargo
CARGO_BUILD_FLAGS ?= --release

ifdef LANCE_C_PREFIX
LANCE_C_INCDIR ?= $(LANCE_C_PREFIX)/include
LANCE_C_LIBDIR ?= $(LANCE_C_PREFIX)/lib
LANCE_C_BUNDLED = no
else
ifeq ($(USE_PKGCONFIG_LANCE_C),1)
LANCE_C_INCDIR ?= $(shell pkg-config --variable=includedir lance-c)
LANCE_C_LIBDIR ?= $(shell pkg-config --variable=libdir lance-c)
LANCE_C_BUNDLED = no
else
LANCE_C_INCDIR ?= $(LANCE_C_DIR)/include
LANCE_C_LIBDIR ?= $(LANCE_C_DIR)/target/release
LANCE_C_BUNDLED = yes
endif
endif

LANCE_C_SHLIB = $(LANCE_C_LIBDIR)/liblance_c.so

# When we ship liblance_c.so ourselves it lands next to lance_fdw.so, so that is
# what the runtime loader has to look at; an external one stays where it is.
ifeq ($(LANCE_C_BUNDLED),yes)
LANCE_C_RPATH = $(pkglibdir)
else
LANCE_C_RPATH = $(LANCE_C_LIBDIR)
endif

PG_CPPFLAGS += -I$(LANCE_C_INCDIR) -Ivendor/nanoarrow/include -Isrc
SHLIB_LINK += -L$(LANCE_C_LIBDIR) -llance_c -Wl,-rpath,$(LANCE_C_RPATH) -lpthread

# ---------------------------------------------------------------------------
# Host-side syntax check (no PostgreSQL installation required)
# ---------------------------------------------------------------------------

SYNTAX_CC ?= gcc
PG_INCLUDE_DIR ?= /opt/cloudberry/src/include
SYNTAX_INCLUDES = -I$(PG_INCLUDE_DIR) -I$(LANCE_C_INCDIR) -Ivendor/nanoarrow/include -Isrc
SYNTAX_CFLAGS ?= -fsyntax-only -Wall -Wno-unused-parameter

.PHONY: check-syntax
check-syntax:
	@set -e; \
	for f in src/*.c; do \
		echo "  SYNTAX  $$f"; \
		$(SYNTAX_CC) $(SYNTAX_CFLAGS) $(SYNTAX_INCLUDES) $$f; \
	done; \
	echo "check-syntax: all sources parse"

# The gate scripts cannot run here (no docker), so the most this host can do is
# parse them.
.PHONY: check-scripts
check-scripts:
	@set -e; \
	for f in test/gate/*.sh; do \
		echo "  BASH -n  $$f"; \
		bash -n $$f; \
	done; \
	echo "check-scripts: all scripts parse"

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs 2>/dev/null)

ifeq ($(PGXS),)

# No server installation in reach: check-syntax above is the only usable target.
all:
	@echo "lance_fdw: '$(PG_CONFIG)' not found - only 'make check-syntax' works here" >&2; \
	exit 1

else

include $(PGXS)

# Makefile.global normally carries these, but an unstripped 230 MiB library in
# $(pkglibdir) is bad enough to be worth a fallback.
ifeq ($(strip $(STRIP_SHARED_LIB)),)
STRIP_SHARED_LIB = strip --strip-unneeded
endif

# lance_fdw.so links against liblance_c.so, so that has to exist first.
$(shlib): $(LANCE_C_SHLIB)

$(LANCE_C_SHLIB):
ifeq ($(LANCE_C_BUNDLED),yes)
	@test -f $(LANCE_C_DIR)/Cargo.toml || { \
		echo "lance_fdw: $(LANCE_C_DIR) is empty - run 'git submodule update --init'" >&2; \
		exit 1; }
	@echo "lance_fdw: building lance-c with cargo (~16 minutes from a cold target/)"
	cd $(LANCE_C_DIR) && $(CARGO) build $(CARGO_BUILD_FLAGS)
else
	@echo "lance_fdw: $(LANCE_C_SHLIB) not found - fix LANCE_C_PREFIX/LANCE_C_LIBDIR" >&2; \
	exit 1
endif

install: install-lance-c
uninstall: uninstall-lance-c

.PHONY: install-lance-c uninstall-lance-c clean-lance-c

install-lance-c: $(LANCE_C_SHLIB)
ifeq ($(LANCE_C_BUNDLED),yes)
	$(MKDIR_P) '$(DESTDIR)$(pkglibdir)'
	$(INSTALL_SHLIB) '$(LANCE_C_SHLIB)' '$(DESTDIR)$(pkglibdir)/liblance_c.so'
	$(STRIP_SHARED_LIB) '$(DESTDIR)$(pkglibdir)/liblance_c.so'
else
	@echo "lance_fdw: using lance-c from $(LANCE_C_LIBDIR), nothing to install"
endif

uninstall-lance-c:
ifeq ($(LANCE_C_BUNDLED),yes)
	rm -f '$(DESTDIR)$(pkglibdir)/liblance_c.so'
endif

# Deliberately not wired into `clean`: rebuilding lance-c costs a quarter of an
# hour, and `make clean` is expected to be cheap.  test/gate/gate.sh --clean
# asks for this one explicitly.
clean-lance-c:
	cd $(LANCE_C_DIR) && $(CARGO) clean

endif
