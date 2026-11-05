/* 0.5.322: the live COS Control stand-in for Tests/app-update-escalation-checks.py. It never quits by itself (a quit
 * that is blocked), so only the update swap's signals end it.
 *   live-app ignore <marker> [hold]   logs "TERM <pid>" to <marker> on SIGTERM and keeps running (only SIGKILL ends it)
 *   live-app die <marker> [hold]      logs "TERM <pid>", then dies of SIGTERM (exit by that signal, never SIGKILL)
 * With [hold] it also keeps that file open, the way a scan or a signature check holds the live executable without
 * running it. It writes "READY <pid>" to <marker> once its handler is in place; a TERM line also carries the wall-clock
 * time it arrived, in milliseconds, so the test can measure each grace.
 *
 * 0.5.373: a Control that quits when the swap asks (AppUpdateQuitRequest in Sources/AppQuit.swift).
 *   live-app listen <marker> <bundle>  logs "QUITREQ <pid> <ms> <object>" for every request the swap posts; when the
 *                                      object is <bundle> it logs "QUIT <pid> <ms>" and exits 0 by itself. Any other
 *                                      object is logged and ignored. SIGTERM logs TERM and dies of it, as "die" does.
 * Built with -framework CoreFoundation (Tests/run.sh, Tests/mutate-app-update-escalation.py). */
#include <CoreFoundation/CoreFoundation.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static const char *marker;
static const char *expected;
static int die;

static void note_with(const char *what, const char *extra) {
    int fd = open(marker, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd < 0) return;
    char line[2200];
    struct timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    long long ms = (long long)now.tv_sec * 1000 + now.tv_nsec / 1000000;
    int n = extra ? snprintf(line, sizeof line, "%s %d %lld %s\n", what, (int)getpid(), ms, extra)
                  : snprintf(line, sizeof line, "%s %d %lld\n", what, (int)getpid(), ms);
    if (n > 0) write(fd, line, (size_t)(n < (int)sizeof line ? n : (int)sizeof line - 1));
    close(fd);
}

static void note(const char *what) { note_with(what, NULL); }

static void on_term(int sig) {
    note("TERM");
    if (die) { signal(sig, SIG_DFL); raise(sig); }
}

/* Same string as AppUpdateQuitRequest.name and the helper's appUpdateQuitRequestName (app-update-quit-request-pins.py). */
#define QUIT_REQUEST_NAME "com.gotcos.control.appUpdate.quitRequest"

static void on_request(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object,
                       CFDictionaryRef info) {
    (void)center; (void)observer; (void)name; (void)info;
    char text[2048] = "";
    if (object && CFGetTypeID(object) == CFStringGetTypeID()) {
        CFStringGetCString((CFStringRef)object, text, sizeof text, kCFStringEncodingUTF8);
    }
    note_with("QUITREQ", text[0] ? text : "-");
    if (strcmp(text, expected) == 0) {
        note("QUIT");
        exit(0);
    }
}

int main(int argc, char **argv) {
    if (argc < 3) return 64;
    die = strcmp(argv[1], "die") == 0;
    marker = argv[2];
    if (strcmp(argv[1], "listen") == 0) {
        if (argc < 4) return 64;
        expected = argv[3];
        die = 1;
        signal(SIGTERM, on_term);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDistributedCenter(), NULL, on_request, CFSTR(QUIT_REQUEST_NAME), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.3, false);   /* let the registration reach distnoted before READY */
        note("READY");
        for (;;) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 60, false);
    }
    signal(SIGTERM, on_term);
    if (argc > 3 && open(argv[3], O_RDONLY) < 0) return 66;
    note("READY");
    for (;;) pause();
}
