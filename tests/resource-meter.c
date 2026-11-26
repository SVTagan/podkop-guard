#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* Lab-only Linux child-tree meter. Adopt orphaned descendants across setsid. */
#define CAP 4096
struct proc { long pid, parent, birth, rss; int owned; };
static struct proc rows[CAP], seen[CAP];
static size_t seen_n;
static long peak_rss, peak_count, peak_tmp, idle_min = -1, idle_max;
static unsigned scans, idle_scans;
static const char *slot = "/tmp/podkop-guard-probe.lock/active";
static long ms(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t)) exit(125);
    return t.tv_sec * 1000L + t.tv_nsec / 1000000;
}
static long us(struct timeval t) { return t.tv_sec * 1000000L + t.tv_usec; }
static int read_proc(long pid, struct proc *p) {
    char path[80], buf[4096], *end, *v, *save;
    snprintf(path, sizeof(path), "/proc/%ld/stat", pid);
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    int ok = fgets(buf, sizeof(buf), f) != NULL;
    fclose(f);
    if (!ok || !(end = strrchr(buf, ')'))) return 0;
    p->pid = pid; p->owned = 0;
    v = strtok_r(end + 1, " ", &save);
    for (int field = 3; field <= 24; field++) {
        if (!v) return 0;
        if (field == 4) p->parent = strtol(v, NULL, 10);
        if (field == 22) p->birth = strtol(v, NULL, 10);
        if (field == 24) p->rss = strtol(v, NULL, 10);
        v = strtok_r(NULL, " ", &save);
    }
    return p->birth > 0 && p->rss >= 0;
}
static long slot_bytes(const char *path) {
    DIR *d = opendir(path);
    if (!d) return 0;
    long total = 0;
    struct dirent *e;
    while ((e = readdir(d))) {
        char file[512]; struct stat st;
        if (snprintf(file, sizeof(file), "%s/%s", path, e->d_name) >= (int)sizeof(file)) continue;
        if (!lstat(file, &st) && S_ISREG(st.st_mode)) total += st.st_size;
    }
    closedir(d); return total;
}
static void sample(long owner, long page_kib) {
    DIR *d = opendir("/proc");
    if (!d) exit(125);
    size_t n = 0; struct dirent *e;
    while ((e = readdir(d))) {
        char *end; long pid = strtol(e->d_name, &end, 10);
        if (*end || pid <= 1 || pid == owner) continue;
        if (n == CAP) exit(125);
        if (read_proc(pid, &rows[n])) n++;
    }
    closedir(d);
    /* Descendants may be reparented to this subreaper after group cleanup. */
    int changed;
    do {
        changed = 0;
        for (size_t i = 0; i < n; i++) {
            if (rows[i].owned) continue;
            int owned = rows[i].parent == owner;
            for (size_t j = 0; !owned && j < n; j++)
                owned = rows[j].owned && rows[j].pid == rows[i].parent;
            if (owned) { rows[i].owned = 1; changed = 1; }
        }
    } while (changed);
    long rss = 0, count = 0;
    for (size_t i = 0; i < n; i++) if (rows[i].owned) {
        rss += rows[i].rss * page_kib; count++;
        size_t j = 0;
        while (j < seen_n && (seen[j].pid != rows[i].pid || seen[j].birth != rows[i].birth)) j++;
        if (j == seen_n) {
            if (seen_n == CAP) exit(125);
            seen[seen_n++] = rows[i];
        }
    }
    if (rss > peak_rss) peak_rss = rss;
    if (count > peak_count) peak_count = count;
    struct stat st;
    if (count && lstat(slot, &st) && errno == ENOENT) {
        if (idle_min < 0 || rss < idle_min) idle_min = rss;
        if (rss > idle_max) idle_max = rss;
        idle_scans++;
    }
    long bytes = slot_bytes(slot) + slot_bytes("/tmp/podkop-guard-probe.lock/active.abandoned");
    if (bytes > peak_tmp) peak_tmp = bytes;
    scans++;
}
int main(int argc, char **argv) {
    if (argc < 2 || prctl(PR_SET_CHILD_SUBREAPER, 1)) return 125;
    long page_kib = sysconf(_SC_PAGESIZE) / 1024;
    if (page_kib <= 0) return 125;
    long start = ms(), owner = getpid(), user = 0, sys = 0, maxrss = 0;
    pid_t root = fork();
    if (root < 0) return 125;
    if (!root) { execvp(argv[1], argv + 1); _exit(127); }
    int root_rc = 125, root_done = 0;
    for (;;) {
        int status; struct rusage ru;
        pid_t pid = wait4(-1, &status, WNOHANG, &ru);
        if (pid > 0) {
            user += us(ru.ru_utime); sys += us(ru.ru_stime);
            if (ru.ru_maxrss > maxrss) maxrss = ru.ru_maxrss;
            if (pid == root) { root_done = 1; root_rc = WIFEXITED(status) ? WEXITSTATUS(status) : 125; }
            continue;
        }
        if (pid < 0 && errno == ECHILD) break;
        if (pid < 0 && errno != EINTR) return 125;
        /* Outer disposable VM timeout remains authoritative on meter error. */
        if (ms() - start > 45000) return 125;
        sample(owner, page_kib);
        struct timespec delay = {0, 20000000};
        nanosleep(&delay, NULL);
    }
    if (!root_done || !scans) return 125;
    printf("PG_RESOURCE wall_ms=%ld user_us=%ld sys_us=%ld max_single_rss_kib=%ld sampled_tree_rss_kib=%ld sampled_peak_tasks=%ld observed_processes=%zu sampled_tmp_bytes=%ld scans=%u outside_slot_min_rss_kib=%ld outside_slot_max_rss_kib=%ld outside_slot_scans=%u rc=%d\n",
           ms() - start, user, sys, maxrss, peak_rss, peak_count, seen_n, peak_tmp, scans, idle_min, idle_max, idle_scans, root_rc);
    return root_rc;
}
