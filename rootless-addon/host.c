// Private test host: host <dylib> <symbol> <arg> [idle-seconds]
// Loads the dylib outside SpringBoard and calls int symbol(const char *arg).
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "usage: host <dylib> <symbol> <arg> [idle-seconds]\n");
		return 2;
	}
	void *handle = dlopen(argv[1], RTLD_NOW);
	if (!handle) {
		fprintf(stderr, "dlopen: %s\n", dlerror());
		return 3;
	}
	int (*fn)(const char *) = dlsym(handle, argv[2]);
	if (!fn) {
		fprintf(stderr, "dlsym: %s\n", dlerror());
		return 4;
	}
	int result = fn(argv[3]);
	printf("%s -> %d\n", argv[2], result);
	if (argc > 4) sleep(atoi(argv[4]));
	return 0;
}
