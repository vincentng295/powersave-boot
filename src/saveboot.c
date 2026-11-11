/*
 * saveboot - giảm tải CPU trong lúc boot, rồi giữ CPU ở chế độ tiết kiệm.
 *
 *   saveboot --first-stage    (post-fs-data)
 *       - mọi cụm: governor powersave, min = max = xung thấp nhất
 *       - tắt hết core, chỉ giữ 1 core yếu nhất (core đầu của cụm có xung max thấp nhất)
 *       - khoá governor/min/max của cụm còn lại bằng bind mount file stub
 *
 *   saveboot --second-stage   (service / late_start)
 *       - chờ sys.boot_completed = 1, chờ thêm 30 giây
 *       - bật lại toàn bộ core
 *       - mọi cụm: governor powersave, max = 1/2 xung cao nhất, min = xung thấp nhất
 *       - khoá lại bằng bind mount file stub để không bị ghi đè
 *
 *   saveboot --unlock         gỡ toàn bộ stub (để chỉnh tay)
 *
 * Cách khoá: ghi giá trị vào sysfs thật, tạo file thường (stub) chứa đúng giá trị đó rồi
 * mount --bind đè lên file sysfs. Từ đó mọi tiến trình đọc/ghi đều đụng vào stub,
 * không tác động được vào kernel.
 */
#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/xattr.h>
#include <time.h>
#include <unistd.h>

#ifdef __ANDROID__
#include <sys/system_properties.h>
#endif

/* Các đường dẫn có thể ghi đè lúc biên dịch để test trên cây sysfs giả */
#ifndef CPU_SYSFS
#define CPU_SYSFS "/sys/devices/system/cpu"
#endif
#ifndef STATE_DIR
#define STATE_DIR "/dev/saveboot" /* tmpfs, mất sau reboot */
#endif

#define STUB_DIR STATE_DIR "/stub"
#define LOG_FILE STATE_DIR "/saveboot.log"

#define GOVERNOR "powersave"
#define DEFAULT_DELAY_SEC 30    /* chờ sau boot_completed */
#define BOOT_TIMEOUT_SEC 600    /* quá hạn mà chưa boot xong thì vẫn trả core về, tránh kẹt 1 core */
#define POLICY_WAIT_MS 10000    /* chờ cpufreq của core vừa bật xuất hiện */
#define MAX_POLICIES 32
#define MAX_CPUS 128

struct policy {
    char path[PATH_MAX];
    long min_khz;  /* cpuinfo_min_freq */
    long max_khz;  /* cpuinfo_max_freq */
    int first_cpu; /* cpu đầu tiên của cụm */
};

static const char *g_tag = "saveboot";

/* ---------------------------------------------------------------- tiện ích */

static void logmsg(const char *fmt, ...)
{
    char msg[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof msg, fmt, ap);
    va_end(ap);

    fprintf(stdout, "[%s] %s\n", g_tag, msg);
    fflush(stdout);

    FILE *f = fopen(LOG_FILE, "a");
    if (f) {
        fprintf(f, "%ld [%s] %s\n", (long)time(NULL), g_tag, msg);
        fclose(f);
    }
}

static void pathf(char *dst, size_t n, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(dst, n, fmt, ap);
    va_end(ap);
}

static int read_str(const char *path, char *buf, size_t sz)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return -1;
    ssize_t n = read(fd, buf, sz - 1);
    close(fd);
    if (n < 0)
        return -1;
    buf[n] = '\0';
    while (n > 0 && isspace((unsigned char)buf[n - 1]))
        buf[--n] = '\0';
    return 0;
}

static int read_long(const char *path, long *out)
{
    char b[64];
    if (read_str(path, b, sizeof b) < 0)
        return -1;
    char *end;
    errno = 0;
    long v = strtol(b, &end, 10);
    if (end == b || errno != 0)
        return -1;
    *out = v;
    return 0;
}

/* sysfs cần ghi trọn giá trị trong một lần write(); O_TRUNC giống `echo x > file` */
static int write_str(const char *path, const char *s)
{
    int fd = open(path, O_WRONLY | O_TRUNC | O_CLOEXEC);
    if (fd < 0)
        return -1;
    size_t len = strlen(s);
    ssize_t n = write(fd, s, len);
    int saved = errno;
    close(fd);
    if (n != (ssize_t)len) {
        errno = (n < 0) ? saved : EIO;
        return -1;
    }
    return 0;
}

static void ensure_dirs(void)
{
    mkdir(STATE_DIR, 0700);
    mkdir(STUB_DIR, 0700);
}

static void msleep(int ms)
{
    struct timespec ts = { ms / 1000, (long)(ms % 1000) * 1000000L };
    nanosleep(&ts, NULL);
}

static int boot_completed(void)
{
#ifdef __ANDROID__
    char v[PROP_VALUE_MAX] = "";
    __system_property_get("sys.boot_completed", v);
    return strcmp(v, "1") == 0;
#else
    return 1; /* build host để test: coi như boot xong */
#endif
}

/* ---------------------------------------------------------- policy / cpu */

static int cmp_policy(const void *a, const void *b)
{
    return ((const struct policy *)a)->first_cpu - ((const struct policy *)b)->first_cpu;
}

/* Trả 1 nếu đọc đủ thông tin; hint = số cpu/policy suy ra từ tên thư mục */
static int fill_policy(struct policy *p, int hint, int dedupe)
{
    char f[PATH_MAX], rel[256];

    pathf(f, sizeof f, "%s/cpuinfo_min_freq", p->path);
    if (read_long(f, &p->min_khz) < 0)
        return 0;
    pathf(f, sizeof f, "%s/cpuinfo_max_freq", p->path);
    if (read_long(f, &p->max_khz) < 0)
        return 0;

    p->first_cpu = hint;
    pathf(f, sizeof f, "%s/related_cpus", p->path);
    if (read_str(f, rel, sizeof rel) == 0 && isdigit((unsigned char)rel[0])) {
        int first = atoi(rel);
        if (dedupe && first != hint)
            return 0; /* cpu này thuộc policy của cpu khác, đã được tính */
        p->first_cpu = first;
    }
    return 1;
}

/* Ưu tiên theo cụm: cpufreq/policyN; fallback: cpuN/cpufreq */
static int load_policies(struct policy *out, int cap)
{
    int n = 0;
    DIR *d = opendir(CPU_SYSFS "/cpufreq");
    if (d) {
        struct dirent *e;
        while ((e = readdir(d)) != NULL && n < cap) {
            if (strncmp(e->d_name, "policy", 6) != 0 || !isdigit((unsigned char)e->d_name[6]))
                continue;
            pathf(out[n].path, sizeof out[n].path, CPU_SYSFS "/cpufreq/%s", e->d_name);
            if (fill_policy(&out[n], atoi(e->d_name + 6), 0))
                n++;
        }
        closedir(d);
    }

    if (n == 0) {
        for (int c = 0; c < MAX_CPUS && n < cap; c++) {
            pathf(out[n].path, sizeof out[n].path, CPU_SYSFS "/cpu%d/cpufreq", c);
            if (access(out[n].path, F_OK) != 0)
                continue;
            if (fill_policy(&out[n], c, 1))
                n++;
        }
    }

    qsort(out, (size_t)n, sizeof out[0], cmp_policy);
    return n;
}

static int list_cpus(int *cpus, int cap)
{
    int n = 0;
    DIR *d = opendir(CPU_SYSFS);
    if (!d)
        return 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL && n < cap) {
        if (strncmp(e->d_name, "cpu", 3) != 0)
            continue;
        const char *s = e->d_name + 3;
        if (!*s)
            continue;
        const char *q = s;
        while (isdigit((unsigned char)*q))
            q++;
        if (*q != '\0') /* loại cpufreq, cpuidle, ... */
            continue;
        cpus[n++] = atoi(s);
    }
    closedir(d);
    return n;
}

/* 0 = ok, 1 = cpu không có nút online (không hotplug được), -1 = ghi lỗi */
static int set_online(int cpu, int on)
{
    char f[PATH_MAX];
    pathf(f, sizeof f, CPU_SYSFS "/cpu%d/online", cpu);
    if (access(f, F_OK) != 0)
        return 1;
    return write_str(f, on ? "1" : "0");
}

/* ------------------------------------------------------------- khoá file */

static void unlock_file(const char *path)
{
    /* gỡ mọi tầng mount chồng lên nhau; lỗi EINVAL nghĩa là hết mount */
    for (int i = 0; i < 8; i++)
        if (umount2(path, MNT_DETACH) != 0)
            break;
}

/* Ghi giá trị vào sysfs thật, rồi bind mount stub chứa đúng giá trị thực tế đè lên */
static int lock_file(const char *path, const char *value)
{
    char stub[PATH_MAX], actual[256], ctx[256];

    unlock_file(path);
    chmod(path, 0644);

    if (write_str(path, value) != 0) {
        logmsg("ghi %s = %s lỗi: %s (bỏ qua khoá)", path, value, strerror(errno));
        return -1;
    }

    /* kernel có thể làm tròn giá trị: stub phải phản ánh đúng giá trị thật */
    if (read_str(path, actual, sizeof actual) != 0 || actual[0] == '\0')
        snprintf(actual, sizeof actual, "%s", value);

    size_t k = 0;
    k += (size_t)snprintf(stub, sizeof stub, STUB_DIR "/");
    for (const char *s = path; *s && k + 1 < sizeof stub; s++)
        stub[k++] = (*s == '/') ? '_' : *s;
    stub[k] = '\0';

    unlink(stub);
    int fd = open(stub, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0444);
    if (fd < 0) {
        logmsg("tạo stub %s lỗi: %s", stub, strerror(errno));
        return -1;
    }
    dprintf(fd, "%s\n", actual);
    close(fd);

    /* chép nhãn SELinux của file gốc, nếu không các tiến trình hệ thống sẽ bị chặn đọc */
    ssize_t n = getxattr(path, "security.selinux", ctx, sizeof ctx);
    if (n > 0)
        setxattr(stub, "security.selinux", ctx, (size_t)n, 0);

    if (mount(stub, path, NULL, MS_BIND, NULL) != 0) {
        logmsg("mount --bind %s lỗi: %s", path, strerror(errno));
        unlink(stub);
        return -1;
    }
    /* remount chỉ đọc: ghi đè bị từ chối (EROFS), giá trị đọc ra luôn đúng giá trị đã khoá */
    if (mount(NULL, path, NULL, MS_BIND | MS_REMOUNT | MS_RDONLY, NULL) != 0)
        logmsg("remount chỉ đọc %s lỗi: %s (stub vẫn được mount)", path, strerror(errno));
    logmsg("khoá %s = %s", path, actual);
    return 0;
}

static void unlock_policy(const struct policy *p)
{
    static const char *const names[] = { "scaling_governor", "scaling_min_freq", "scaling_max_freq" };
    char f[PATH_MAX];
    for (size_t i = 0; i < sizeof names / sizeof names[0]; i++) {
        pathf(f, sizeof f, "%s/%s", p->path, names[i]);
        unlock_file(f);
    }
}

static void lock_policy(const struct policy *p, long min_khz, long max_khz)
{
    char f[PATH_MAX], v[32];

    /* thứ tự: min thấp trước -> max -> governor */
    pathf(f, sizeof f, "%s/scaling_min_freq", p->path);
    snprintf(v, sizeof v, "%ld", min_khz);
    lock_file(f, v);

    pathf(f, sizeof f, "%s/scaling_max_freq", p->path);
    snprintf(v, sizeof v, "%ld", max_khz);
    lock_file(f, v);

    pathf(f, sizeof f, "%s/scaling_governor", p->path);
    lock_file(f, GOVERNOR);
}

/* ------------------------------------------------------------ first stage */

static int first_stage(void)
{
    struct policy pol[MAX_POLICIES];
    int cpus[MAX_CPUS];

    g_tag = "first-stage";
    ensure_dirs();

    int np = load_policies(pol, MAX_POLICIES);
    if (np == 0)
        logmsg("không thấy cpufreq policy nào");

    /* cụm yếu nhất = xung max thấp nhất (hoà thì lấy cụm có cpu số nhỏ hơn) */
    int weak = -1;
    for (int i = 0; i < np; i++)
        if (weak < 0 || pol[i].max_khz < pol[weak].max_khz)
            weak = i;
    int keep = (weak >= 0) ? pol[weak].first_cpu : 0;
    logmsg("%d cụm, giữ lại cpu%d", np, keep);

    /* 1) powersave + xung thấp nhất cho mọi cụm (làm trước khi tắt core vì policy sẽ biến mất) */
    for (int i = 0; i < np; i++) {
        char f[PATH_MAX], v[32];
        snprintf(v, sizeof v, "%ld", pol[i].min_khz);

        pathf(f, sizeof f, "%s/scaling_governor", pol[i].path);
        chmod(f, 0644);
        if (write_str(f, GOVERNOR) != 0)
            logmsg("%s: ghi governor lỗi: %s", pol[i].path, strerror(errno));
        pathf(f, sizeof f, "%s/scaling_min_freq", pol[i].path);
        chmod(f, 0644);
        write_str(f, v);
        pathf(f, sizeof f, "%s/scaling_max_freq", pol[i].path);
        chmod(f, 0644);
        write_str(f, v);
    }

    /* 2) tắt tất cả core trừ core được giữ */
    int nc = list_cpus(cpus, MAX_CPUS);
    int off = 0;
    for (int i = 0; i < nc; i++) {
        if (cpus[i] == keep)
            continue;
        int r = set_online(cpus[i], 0);
        if (r == 0)
            off++;
        else if (r < 0)
            logmsg("tắt cpu%d lỗi: %s", cpus[i], strerror(errno));
    }
    logmsg("đã tắt %d core", off);

    /* 3) khoá cụm còn lại để không bị ghi đè trong lúc boot */
    if (weak >= 0)
        lock_policy(&pol[weak], pol[weak].min_khz, pol[weak].min_khz);

    return 0;
}

/* ----------------------------------------------------------- second stage */

/* mức xung có sẵn lớn nhất mà <= 1/2 xung cao nhất của cụm */
static long half_target(const struct policy *p)
{
    char f[PATH_MAX], buf[2048];
    long half = p->max_khz / 2, best = 0;

    pathf(f, sizeof f, "%s/scaling_available_frequencies", p->path);
    if (read_str(f, buf, sizeof buf) == 0) {
        char *save = NULL;
        for (char *tok = strtok_r(buf, " \t\n", &save); tok; tok = strtok_r(NULL, " \t\n", &save)) {
            long v = strtol(tok, NULL, 10);
            if (v > 0 && v <= half && v > best)
                best = v;
        }
    }
    if (best == 0)
        best = half;
    if (best < p->min_khz)
        best = p->min_khz;
    return best;
}

static int cpus_have_cpufreq(const int *cpus, int n)
{
    char f[PATH_MAX];
    for (int i = 0; i < n; i++) {
        pathf(f, sizeof f, CPU_SYSFS "/cpu%d/cpufreq", cpus[i]);
        if (access(f, F_OK) != 0)
            return 0;
    }
    return 1;
}

static int second_stage(int delay)
{
    struct policy pol[MAX_POLICIES];
    int cpus[MAX_CPUS];

    g_tag = "second-stage";
    ensure_dirs();

    /* 1) chờ boot_completed, rồi chờ thêm */
    int waited = 0;
    while (!boot_completed() && waited < BOOT_TIMEOUT_SEC) {
        sleep(1);
        waited++;
    }
    if (waited >= BOOT_TIMEOUT_SEC)
        logmsg("quá %d giây vẫn chưa boot_completed, tiếp tục", BOOT_TIMEOUT_SEC);
    logmsg("boot_completed sau %d giây, chờ thêm %d giây", waited, delay);
    if (delay > 0)
        sleep((unsigned)delay);

    /* 2) gỡ stub cũ của cụm đang có */
    int np = load_policies(pol, MAX_POLICIES);
    for (int i = 0; i < np; i++)
        unlock_policy(&pol[i]);

    /* 3) bật lại toàn bộ core */
    int nc = list_cpus(cpus, MAX_CPUS);
    int on = 0;
    for (int i = 0; i < nc; i++) {
        int r = set_online(cpus[i], 1);
        if (r == 0)
            on++;
        else if (r < 0)
            logmsg("bật cpu%d lỗi: %s", cpus[i], strerror(errno));
    }
    logmsg("đã bật %d core", on);

    /* 4) chờ cpufreq của các core vừa bật xuất hiện */
    for (int t = 0; t < POLICY_WAIT_MS && !cpus_have_cpufreq(cpus, nc); t += 500)
        msleep(500);

    /* 5) áp cấu hình cuối + khoá bằng stub */
    np = load_policies(pol, MAX_POLICIES);
    for (int i = 0; i < np; i++) {
        long target = half_target(&pol[i]);
        logmsg("%s: min=%ld max=%ld (cao nhất %ld)", pol[i].path, pol[i].min_khz, target, pol[i].max_khz);
        lock_policy(&pol[i], pol[i].min_khz, target);
    }
    return 0;
}

/* ---------------------------------------------------------------- unlock */

static int unlock_all(void)
{
    struct policy pol[MAX_POLICIES];
    g_tag = "unlock";
    int np = load_policies(pol, MAX_POLICIES);
    for (int i = 0; i < np; i++)
        unlock_policy(&pol[i]);
    logmsg("đã gỡ stub của %d cụm", np);
    return 0;
}

/* ------------------------------------------------------------------ main */

static void usage(const char *argv0)
{
    fprintf(stderr,
            "Cách dùng: %s <lệnh> [tuỳ chọn]\n"
            "  --first-stage        tắt hết core trừ 1 core yếu nhất, powersave + xung thấp nhất, khoá stub\n"
            "  --second-stage       chờ boot xong, bật lại core, powersave + max = 1/2 xung cao nhất, khoá stub\n"
            "  --unlock             gỡ toàn bộ stub\n"
            "  --delay <giây>       thời gian chờ sau boot_completed cho --second-stage (mặc định %d)\n"
            "  -h, --help           trợ giúp\n",
            argv0, DEFAULT_DELAY_SEC);
}

int main(int argc, char **argv)
{
    enum { NONE, FIRST, SECOND, UNLOCK } mode = NONE;
    int delay = DEFAULT_DELAY_SEC;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--first-stage")) {
            mode = FIRST;
        } else if (!strcmp(argv[i], "--second-stage")) {
            mode = SECOND;
        } else if (!strcmp(argv[i], "--unlock")) {
            mode = UNLOCK;
        } else if (!strcmp(argv[i], "--delay") && i + 1 < argc) {
            delay = atoi(argv[++i]);
        } else if (!strncmp(argv[i], "--delay=", 8)) {
            delay = atoi(argv[i] + 8);
        } else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            usage(argv[0]);
            return 0;
        } else {
            fprintf(stderr, "tham số không hợp lệ: %s\n", argv[i]);
            usage(argv[0]);
            return 2;
        }
    }

    if (mode == NONE) {
        usage(argv[0]);
        return 2;
    }
    if (delay < 0)
        delay = 0;
    if (geteuid() != 0)
        fprintf(stderr, "cảnh báo: không chạy bằng root, nhiều thao tác sẽ thất bại\n");

    switch (mode) {
    case FIRST:  return first_stage();
    case SECOND: return second_stage(delay);
    case UNLOCK: return unlock_all();
    default:     return 2;
    }
}
