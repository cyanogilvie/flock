DESTDIR=/usr/local
VER=0.5

all: tm

tm: tm/flock-$(VER).tm

# depends on bird.tcl and testscripts/Makefile to ensure the bird containers are restarted if the code changes
tm/flock-$(VER).tm: flock.tcl testscripts/bird.tcl testscripts/Makefile
	mkdir -p tm
	cp flock.tcl tm/flock-$(VER).tm
	-docker-compose restart bird1 bird2 bird3

clean:
	-docker-compose down --remove-orphans
	-rm -rf tm/flock-*.tm

install: tm
	mkdir -p $(DESTDIR)/lib/tcl8/site-tcl
	cp tm/* $(DESTDIR)/lib/tcl8/site-tcl/

test: tm
	docker-compose run --rm conductor test TESTFLAGS="$(TESTFLAGS)"

.PHONY: tm install clean test
