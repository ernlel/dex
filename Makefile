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

VERSION ?= 0.4.0
DIST_DIR = dist
DIST_NAME = dex-$(VERSION)
DIST_BIN_NAME = dex-$(VERSION)-linux-x86_64

# Compiler flags (release optimized by default)
DFLAGS ?= -O -release -inline

.PHONY: all clean test install uninstall dist dist-bin

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

dist:
	rm -rf $(DIST_DIR)/$(DIST_NAME) $(DIST_DIR)/$(DIST_NAME).tar.gz $(DIST_DIR)/$(DIST_NAME).zip
	mkdir -p $(DIST_DIR)/$(DIST_NAME)/source/dex
	cp LICENSE Makefile dub.json README.md $(DIST_DIR)/$(DIST_NAME)/
	cp $(D_SRC) $(DIST_DIR)/$(DIST_NAME)/source/dex/
	cd $(DIST_DIR) && tar -czf $(DIST_NAME).tar.gz $(DIST_NAME)
	cd $(DIST_DIR) && zip -q -r $(DIST_NAME).zip $(DIST_NAME)
	rm -rf $(DIST_DIR)/$(DIST_NAME)
	@echo "Created $(DIST_DIR)/$(DIST_NAME).tar.gz and $(DIST_DIR)/$(DIST_NAME).zip"

dist-bin: $(LIB)
	rm -rf $(DIST_DIR)/$(DIST_BIN_NAME) $(DIST_DIR)/$(DIST_BIN_NAME).tar.gz
	mkdir -p $(DIST_DIR)/$(DIST_BIN_NAME)/lib $(DIST_DIR)/$(DIST_BIN_NAME)/include/dex
	cp $(LIB) $(DIST_DIR)/$(DIST_BIN_NAME)/lib/
	cp $(D_SRC) $(DIST_DIR)/$(DIST_BIN_NAME)/include/dex/
	cp LICENSE Makefile README.md $(DIST_DIR)/$(DIST_BIN_NAME)/
	cd $(DIST_DIR) && tar -czf $(DIST_BIN_NAME).tar.gz $(DIST_BIN_NAME)
	rm -rf $(DIST_DIR)/$(DIST_BIN_NAME)
	@echo "Created $(DIST_DIR)/$(DIST_BIN_NAME).tar.gz"

clean:
	rm -f $(LIB) $(TEST_BIN) *.o
	rm -rf $(DIST_DIR)

