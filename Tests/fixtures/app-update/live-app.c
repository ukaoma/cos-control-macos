/* 0.5.322: the live COS Control stand-in for Tests/app-update-escalation-checks.py. It never quits by itself (a quit
 * that is blocked), so only the update swap's signals end it.
 *   live-app ignore <marker> [hold]   logs "TERM <pid>" to <marker> on SIGTERM and keeps running (only SIGKILL ends it)
 *   live-app die <marker> [hold]      logs "TERM <pid>", then dies of SIGTERM (exit by that signal, never SIGKILL)
 * With [hold] it also keeps that file open, the way a scan or a signature check holds the live executable without
 * running it. It writes "READY <pid>" to <marker> once its handler is in place; a TERM line also carries the wall-clock
 * time it arrived, in milliseconds, so the test can measure each grace. */
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static const char *marker;
static int die;

static void note(const char *what) {
    int fd = open(marker, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd < 0) return;
    char line[96];
    struct timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    long long ms = (long long)now.tv_sec * 1000 + now.tv_nsec / 1000000;
    int n = snprintf(line, sizeof line, "%s %d %lld\n", what, (int)getpid(), ms);
    if (n > 0) write(fd, line, (size_t)n);
    close(fd);
}

static void on_term(int sig) {
    note("TERM");
    if (die) { signal(sig, SIG_DFL); raise(sig); }
}

int main(int argc, char **argv) {
    if (argc < 3) return 64;
    die = strcmp(argv[1], "die") == 0;
    marker = argv[2];
    signal(SIGTERM, on_term);
    if (argc > 3 && open(argv[3], O_RDONLY) < 0) return 66;
    note("READY");
    for (;;) pause();
}
