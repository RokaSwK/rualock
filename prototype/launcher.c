// Tiny launcher that lives in Localsec.app/Contents/MacOS. It runs the Python watcher as a child,
// so macOS attributes camera access to Localsec.app (one permission prompt, remembered),
// and forwards SIGTERM/SIGINT so `launchctl` can stop it cleanly.
//
// Built by `facelock install` with -DPYTHON="..." -DSCRIPT="...".
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;
static pid_t child = 0;

static void forward(int sig) {
    if (child > 0) kill(child, sig);
}

int main(int argc, char **argv) {
    char **args = calloc(argc + 2, sizeof(char *));
    args[0] = PYTHON;
    args[1] = SCRIPT;
    for (int i = 1; i < argc; i++) args[i + 1] = argv[i];

    signal(SIGTERM, forward);
    signal(SIGINT, forward);
    signal(SIGHUP, forward);

    if (posix_spawn(&child, PYTHON, NULL, NULL, args, environ) != 0) return 127;
    int status = 0;
    while (waitpid(child, &status, 0) < 0) {}
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
