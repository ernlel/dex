DC ?= dmd
PREFIX ?= /usr/local
LIBDIR ?= $(PREFIX)/lib
INCLUDEDIR ?= $(PREFIX)/include/d/dex

D_SRC = source/dex/package.d \
        source/dex/app.d \
        source/dex/errors.d \
        source/dex/http.d \
        source/dex/jsonx.d \
        source/dex/middleware.d \
        source/dex/request.d \
        source/dex/response.d \
        source/dex/router.d \
        source/dex/server.d \
        source/dex/view.d

ALL_SRC = $(D_SRC) source/dex/tests.d

LIB = libdex.a
TEST_BIN = dex-test-runner

# Compiler flags (release optimized by default)
DFLAGS ?= -O -release -inline

.PHONY: all clean test install uninstall

all: $(LIB)

$(LIB): $(D_SRC)
	$(DC) -lib -of=$@ -Isource $(DFLAGS) $(D_SRC)

test: $(TEST_BIN)
	./$(TEST_BIN)

$(TEST_BIN): $(ALL_SRC)
	$(DC) -unittest -main -Isource $(ALL_SRC) -of=$@

install: $(LIB)
	install -d $(DESTDIR)$(LIBDIR)
	install -m 644 $(LIB) $(DESTDIR)$(LIBDIR)
	install -d $(DESTDIR)$(INCLUDEDIR)
	install -m 644 source/dex/*.d $(DESTDIR)$(INCLUDEDIR)

uninstall:
	rm -f $(DESTDIR)$(LIBDIR)/$(LIB)
	rm -rf $(DESTDIR)$(INCLUDEDIR)

clean:
	rm -f $(LIB) $(TEST_BIN) *.o

