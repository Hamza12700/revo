CC ?= cc
CFLAGS ?= -std=c99 -Wall -Wextra -I../../zig-out/include
LIB = ../../zig-out/lib/liberevo.a
UNAME := $(shell uname -s)

# for my specific configuration, this is the only way to make it work on osx15.5
ifeq ($(UNAME), Darwin)
CFLAGS += -mmacosx-version-min=15.5
endif

all: basic extension

$(LIB):
	cd ../.. && zig build lib

basic: basic.c $(LIB)
	$(CC) $(CFLAGS) $< $(LIB) -o $@

extension: extension.c
	$(CC) $(CFLAGS) -shared -fPIC $< -o extension.so -undefined dynamic_lookup

run: basic
	./basic

clean:
	rm -f basic extension.so
