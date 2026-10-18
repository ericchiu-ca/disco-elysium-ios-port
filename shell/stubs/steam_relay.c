// Steam 桩库的"成就模式"（config.env 里 ACH_RELAY=1 时，build_stubs.sh 用它代替 steam_api_overrides.c）。
// 游戏看到的是一个已登录的 Steam，照常调用 SetAchievement / StoreStats；这里只记账：
//   1. 记进 Documents/Achievements/pending.txt（App 被关掉也不会丢）；
//   2. 通过本地网络发给你 Mac 上的 tools/steam_relay.py，由 Mac 上真正的 Steam 客户端解锁
//      （是否拥有这款游戏由那边的 Steam 校验）；
//   3. 连不上 Mac 时先排队，连上后补发；也可以用 make achievements-sync 经 USB 同步。
// 只单向提交：游戏的 ClearAchievement / ResetAllStats 不会转发，不会清掉你 Steam 上的成就。
// The "achievement mode" of the Steam stub (build_stubs.sh uses it instead of steam_api_overrides.c when config.env
// has ACH_RELAY=1). The game sees a logged-in Steam and calls SetAchievement / StoreStats as usual; this file only
// keeps the books:
//   1. records them in Documents/Achievements/pending.txt (nothing is lost if the app is closed);
//   2. sends them over the local network to tools/steam_relay.py on your Mac, where the real Steam client unlocks them
//      (that Steam checks that you own the game);
//   3. queues them while the Mac cannot be reached and sends them once it can; make achievements-sync does the same over USB.
// Commits go one way only: the game's ClearAchievement / ResetAllStats are not forwarded and never clear achievements on Steam.

#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <netdb.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <CommonCrypto/CommonHMAC.h>
#include <CoreFoundation/CoreFoundation.h>

#ifndef DE_STEAM_APP_ID
#error "build_stubs.sh 应当传入 -DDE_STEAM_APP_ID | build_stubs.sh must pass -DDE_STEAM_APP_ID"
#endif
#ifndef DE_RELAY_HOST
#define DE_RELAY_HOST ""
#endif
#ifndef DE_RELAY_PORT
#define DE_RELAY_PORT "47632"
#endif
#ifndef DE_RELAY_SECRET
#define DE_RELAY_SECRET ""
#endif

#define DE_EXPORT __attribute__((visibility("default")))
#define MAX_NAME 64
#define MAX_ACH 128
#define MAX_STAT 32
#define MAX_PENDING 256
#define MAX_CALLBACKS 64

// ---- 日志：stderr 进 Player.log（或 DE_LOG_TO_CONSOLE 时进控制台），同时写系统日志 ----
// ---- Logging: stderr goes to Player.log (or the console with DE_LOG_TO_CONSOLE); the system log gets a copy ----
static void relay_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void relay_log(const char *fmt, ...)
{
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    fprintf(stderr, "[DEPort] steam relay: %s\n", buf);
    os_log(de_stub_log(), "steam relay: %{public}s", buf);
}

// ---- Steamworks 回调结构：macOS 版按 4 字节对齐，游戏代码（Steamworks.NET，StandaloneOSX）按这个布局读取 ----
// ---- Steamworks callback structures: the macOS build packs them to 4 bytes, and the game code (Steamworks.NET,
//      StandaloneOSX) reads them with that layout ----
#pragma pack(push, 4)
typedef struct { int32_t user; int32_t callback; uint8_t *param; int32_t size; } CallbackMsg;                    // CallbackMsg_t
typedef struct { uint64_t gameID; int32_t result; uint64_t steamID; } UserStatsReceived;                         // 1101
typedef struct { uint64_t gameID; int32_t result; } UserStatsStored;                                             // 1102
typedef struct { uint64_t gameID; bool group; char name[128]; uint32_t cur; uint32_t max; } UserAchievementStored; // 1103
#pragma pack(pop)
_Static_assert(sizeof(CallbackMsg) == 20, "CallbackMsg_t layout");
_Static_assert(sizeof(UserStatsReceived) == 20, "UserStatsReceived_t layout");
_Static_assert(sizeof(UserStatsStored) == 12, "UserStatsStored_t layout");
_Static_assert(sizeof(UserAchievementStored) == 148, "UserAchievementStored_t layout");
enum { kUserStatsReceived = 1101, kUserStatsStored = 1102, kUserAchievementStored = 1103, kResultOK = 1 };

typedef struct { int32_t id; int32_t size; uint8_t data[sizeof(UserAchievementStored)]; } QueuedCallback;

// ---- 状态：steam = Steam 上已确认的值；local = 游戏在这台 iPad 上写入、还没确认的值 ----
// ---- State: steam = values confirmed on Steam; local = values the game wrote on this iPad that are not confirmed yet ----
typedef struct { char name[MAX_NAME]; bool steam; bool local; } Ach;
typedef struct { char name[MAX_NAME]; char kind; bool has_steam, has_local; double steam, local; } Stat;
typedef struct { long id; char kind; char name[MAX_NAME]; double value; bool sent; } Pending;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_wake = PTHREAD_COND_INITIALIZER;
static Ach g_ach[MAX_ACH];
static int g_nach;
static Stat g_stat[MAX_STAT];
static int g_nstat;
static Pending g_pend[MAX_PENDING];
static int g_npend;
static long g_next_id = 1;
static char g_persona[128];
static char g_lang[32];
static char g_langs[256];
static uint64_t g_steam_id;
static char g_newly[16][MAX_NAME];  // 上次 StoreStats 之后新解锁的 | unlocked since the last StoreStats
static int g_nnewly;
static QueuedCallback g_cb[MAX_CALLBACKS];
static int g_cb_head, g_cb_count;
static QueuedCallback g_cb_current;
static char g_dir[1024], g_state_path[1100], g_pending_path[1100];
static time_t g_state_mtime;
static uint8_t g_iface[64];  // 游戏只检查接口指针不为空；所有方法都忽略 self | The game only checks that interface pointers are not NULL; every method ignores self

static bool valid_name(const char *s)
{
    if (!s || !*s || strlen(s) >= MAX_NAME) return false;
    for (const char *p = s; *p; p++)
        if (!((*p >= 'A' && *p <= 'Z') || (*p >= 'a' && *p <= 'z') || (*p >= '0' && *p <= '9') || *p == '_' || *p == '.' || *p == '-'))
            return false;
    return true;
}

// 以下函数都在持有 g_lock 时调用 | The functions below are all called with g_lock held
static int ach_index(const char *name, bool create)
{
    for (int i = 0; i < g_nach; i++)
        if (!strcmp(g_ach[i].name, name)) return i;
    if (!create || g_nach == MAX_ACH) return -1;
    memset(&g_ach[g_nach], 0, sizeof g_ach[0]);
    strlcpy(g_ach[g_nach].name, name, MAX_NAME);
    return g_nach++;
}

static int stat_index(const char *name, char kind, bool create)
{
    for (int i = 0; i < g_nstat; i++)
        if (!strcmp(g_stat[i].name, name)) return i;
    if (!create || g_nstat == MAX_STAT) return -1;
    memset(&g_stat[g_nstat], 0, sizeof g_stat[0]);
    strlcpy(g_stat[g_nstat].name, name, MAX_NAME);
    g_stat[g_nstat].kind = kind;
    return g_nstat++;
}

static void push_callback(int32_t id, const void *data, int32_t size)
{
    if (g_cb_count == MAX_CALLBACKS) return;
    QueuedCallback *q = &g_cb[(g_cb_head + g_cb_count) % MAX_CALLBACKS];
    q->id = id;
    q->size = size;
    memcpy(q->data, data, (size_t)size);
    g_cb_count++;
}

static void write_file_atomically(const char *path, const char *text)
{
    char tmp[1200];
    snprintf(tmp, sizeof tmp, "%s.tmp", path);
    FILE *f = fopen(tmp, "w");
    if (!f) return;
    fputs(text, f);
    fclose(f);
    rename(tmp, path);
}

static void save_pending(void)
{
    static char text[MAX_PENDING * 96];
    size_t n = 0;
    text[0] = 0;
    for (int i = 0; i < g_npend && n < sizeof text - 96; i++)
        n += (size_t)snprintf(text + n, sizeof text - n, "%ld %c %s %.17g\n", g_pend[i].id, g_pend[i].kind, g_pend[i].name, g_pend[i].value);
    write_file_atomically(g_pending_path, text);
}

static void load_pending(void)
{
    FILE *f = fopen(g_pending_path, "r");
    if (!f) return;
    char line[256];
    while (g_npend < MAX_PENDING && fgets(line, sizeof line, f)) {
        Pending p = { 0 };
        if (sscanf(line, "%ld %c %63s %lf", &p.id, &p.kind, p.name, &p.value) != 4) continue;
        if ((p.kind != 'A' && p.kind != 'I' && p.kind != 'F') || !valid_name(p.name)) continue;
        g_pend[g_npend++] = p;
        if (p.id >= g_next_id) g_next_id = p.id + 1;
        if (p.kind == 'A') {
            int i = ach_index(p.name, true);
            if (i >= 0) g_ach[i].local = true;
        } else {
            int i = stat_index(p.name, p.kind, true);
            if (i >= 0) { g_stat[i].has_local = true; g_stat[i].local = p.value; }
        }
    }
    fclose(f);
}

// 读 state.txt（Mac 写来的 Steam 状态）：A <成就> 0|1、I|F <统计值> <值>、P 昵称、D SteamID、L 语言、G 可用语言
// Read state.txt (Steam's state as written by the Mac): A <achievement> 0|1, I|F <stat> <value>, P persona, D Steam ID,
// L language, G available languages
static void load_state(void)
{
    struct stat st;
    if (stat(g_state_path, &st) != 0) return;
    FILE *f = fopen(g_state_path, "r");
    if (!f) return;
    g_state_mtime = st.st_mtime;
    for (int i = 0; i < g_nach; i++) g_ach[i].steam = false;
    for (int i = 0; i < g_nstat; i++) g_stat[i].has_steam = false;
    char line[512];
    while (fgets(line, sizeof line, f)) {
        line[strcspn(line, "\r\n")] = 0;
        if (strlen(line) < 2 || line[1] != ' ') continue;
        const char *rest = line + 2;
        char name[MAX_NAME];
        double v;
        switch (line[0]) {
        case 'A': {
            int done;
            if (sscanf(rest, "%63s %d", name, &done) == 2 && valid_name(name)) {
                int i = ach_index(name, true);
                if (i >= 0) g_ach[i].steam = done != 0;
            }
            break;
        }
        case 'I':
        case 'F':
            if (sscanf(rest, "%63s %lf", name, &v) == 2 && valid_name(name)) {
                int i = stat_index(name, line[0], true);
                if (i >= 0) { g_stat[i].has_steam = true; g_stat[i].steam = v; }
            }
            break;
        case 'P': strlcpy(g_persona, rest, sizeof g_persona); break;
        case 'D': g_steam_id = strtoull(rest, NULL, 10); break;
        case 'L': if (*rest) strlcpy(g_lang, rest, sizeof g_lang); break;
        case 'G': if (*rest) strlcpy(g_langs, rest, sizeof g_langs); break;
        }
    }
    fclose(f);
}

// 去掉 Steam 上已经生效的记录 | Drop the entries that have already taken effect on Steam
static void prune_pending(void)
{
    int kept = 0, before = g_npend;
    for (int k = 0; k < g_npend; k++) {
        Pending *p = &g_pend[k];
        bool done = false;
        if (p->kind == 'A') {
            int i = ach_index(p->name, false);
            done = i >= 0 && g_ach[i].steam;
        } else {
            int i = stat_index(p->name, p->kind, false);
            done = i >= 0 && g_stat[i].has_steam && g_stat[i].steam == p->value;
        }
        if (!done) g_pend[kept++] = *p;
    }
    g_npend = kept;
    if (kept != before) save_pending();
}

static void add_pending(char kind, const char *name, double value)
{
    // 统计值只保留最新的一条 | Keep only the latest entry per stat
    for (int k = 0; k < g_npend; k++) {
        if (g_pend[k].kind == kind && !strcmp(g_pend[k].name, name)) {
            if (kind == 'A') return;
            g_pend[k].value = value;
            g_pend[k].sent = false;
            save_pending();
            return;
        }
    }
    if (g_npend == MAX_PENDING) return;
    Pending *p = &g_pend[g_npend++];
    memset(p, 0, sizeof *p);
    p->id = g_next_id++;
    p->kind = kind;
    strlcpy(p->name, name, MAX_NAME);
    p->value = value;
    save_pending();
}

// 没有同步过时，按 iPad 的首选语言给出 Steam 的语言名 | Before any sync, derive Steam's language name from the iPad's preferred language
static void default_language(void)
{
    strlcpy(g_lang, "english", sizeof g_lang);
    CFArrayRef langs = CFLocaleCopyPreferredLanguages();
    if (!langs) return;
    char code[32] = "";
    if (CFArrayGetCount(langs) > 0)
        CFStringGetCString((CFStringRef)CFArrayGetValueAtIndex(langs, 0), code, sizeof code, kCFStringEncodingUTF8);
    CFRelease(langs);
    static const struct { const char *prefix, *steam; } map[] = {
        { "zh-Hans", "schinese" }, { "zh-Hant", "tchinese" }, { "zh-HK", "tchinese" }, { "zh-TW", "tchinese" },
        { "zh", "schinese" }, { "ja", "japanese" }, { "ko", "koreana" }, { "fr", "french" }, { "de", "german" },
        { "es-419", "latam" }, { "es", "spanish" }, { "pt-BR", "brazilian" }, { "pt", "portuguese" },
        { "ru", "russian" }, { "pl", "polish" }, { "tr", "turkish" }, { "it", "italian" }, { "uk", "ukrainian" },
    };
    for (size_t i = 0; i < sizeof map / sizeof map[0]; i++) {
        if (!strncmp(code, map[i].prefix, strlen(map[i].prefix))) {
            strlcpy(g_lang, map[i].steam, sizeof g_lang);
            break;
        }
    }
}

// ---- 与 Mac 的连接（协议见 tools/steam_relay.py） | The connection to the Mac (protocol in tools/steam_relay.py) ----

typedef struct { int fd; char buf[16384]; size_t len; } Conn;

static bool conn_send(int fd, const char *s)
{
    size_t n = strlen(s);
    while (n) {
        ssize_t w = send(fd, s, n, 0);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return false;
        s += w;
        n -= (size_t)w;
    }
    return true;
}

// 读一行（不含换行）：1 = 读到；0 = timeout_ms 内没有完整的一行；-1 = 断开或出错
// Read one line (without the newline): 1 = got one; 0 = no complete line within timeout_ms; -1 = disconnected or error
static int conn_readline(Conn *c, char *out, size_t cap, int timeout_ms)
{
    for (;;) {
        char *nl = memchr(c->buf, '\n', c->len);
        if (nl) {
            size_t n = (size_t)(nl - c->buf), k = n < cap - 1 ? n : cap - 1;
            memcpy(out, c->buf, k);
            out[k] = 0;
            if (k && out[k - 1] == '\r') out[k - 1] = 0;
            memmove(c->buf, nl + 1, c->len - n - 1);
            c->len -= n + 1;
            return 1;
        }
        if (c->len == sizeof c->buf) return -1;
        struct pollfd p = { c->fd, POLLIN, 0 };
        int r = poll(&p, 1, timeout_ms);
        if (r == 0) return 0;
        if (r < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        ssize_t got = recv(c->fd, c->buf + c->len, sizeof c->buf - c->len, 0);
        if (got <= 0) return -1;
        c->len += (size_t)got;
    }
}

static int relay_connect(bool quiet)
{
    struct addrinfo hints = { 0 }, *res = NULL;
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    int rc = getaddrinfo(DE_RELAY_HOST, DE_RELAY_PORT, &hints, &res);
    if (rc) {
        if (!quiet) relay_log("cannot resolve %s: %s", DE_RELAY_HOST, gai_strerror(rc));
        return -1;
    }
    int fd = -1;
    for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;
        int on = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
        fcntl(fd, F_SETFL, O_NONBLOCK);
        if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0 || errno == EINPROGRESS) {
            struct pollfd p = { fd, POLLOUT, 0 };
            int err = 0;
            socklen_t len = sizeof err;
            if (poll(&p, 1, 5000) == 1 && getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0 && err == 0) {
                fcntl(fd, F_SETFL, 0);
                break;
            }
        }
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0 && !quiet) relay_log("cannot reach the Mac at %s:%s (is make relay running there?)", DE_RELAY_HOST, DE_RELAY_PORT);
    return fd;
}

static void ack_pending(long id, bool committed)
{
    pthread_mutex_lock(&g_lock);
    for (int k = 0; k < g_npend; k++) {
        if (g_pend[k].id != id) continue;
        Pending p = g_pend[k];
        memmove(&g_pend[k], &g_pend[k + 1], sizeof(Pending) * (size_t)(g_npend - k - 1));
        g_npend--;
        if (committed && p.kind == 'A') {
            int i = ach_index(p.name, true);
            if (i >= 0) g_ach[i].steam = true;
        } else if (committed) {
            int i = stat_index(p.name, p.kind, true);
            if (i >= 0) { g_stat[i].has_steam = true; g_stat[i].steam = p.value; }
        }
        save_pending();
        pthread_mutex_unlock(&g_lock);
        if (committed) relay_log("%s %s committed to Steam", p.kind == 'A' ? "achievement" : "stat", p.name);
        else relay_log("Steam does not know %s; dropped", p.name);
        return;
    }
    pthread_mutex_unlock(&g_lock);
}

// 一次会话：认证、接收状态、发送记录、保持在线。返回 true 表示曾经连通 | One session: authenticate, receive the state, send the
// entries, stay online. Returns true if the session got through
static bool relay_session(int fd)
{
    static Conn c;
    c.fd = fd;
    c.len = 0;
    char line[1024];
    if (conn_readline(&c, line, sizeof line, 10000) != 1 || strncmp(line, "HELLO DE-STEAM-RELAY 1 ", 23) != 0) {
        relay_log("unexpected greeting from the Mac");
        return false;
    }
    const char *nonce = line + 23;
    unsigned char mac[CC_SHA256_DIGEST_LENGTH];
    // 密钥是十六进制文本，先转成字节 | The secret is hex text; convert it to bytes first
    static const char secret[] = DE_RELAY_SECRET;
    unsigned char key[32];
    size_t keylen = strlen(secret) / 2;
    if (keylen > sizeof key) keylen = sizeof key;
    for (size_t i = 0; i < keylen; i++) sscanf(&secret[2 * i], "%2hhx", &key[i]);
    CCHmac(kCCHmacAlgSHA256, key, keylen, nonce, strlen(nonce), mac);
    char msg[80] = "AUTH ";
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) snprintf(msg + 5 + 2 * i, 3, "%02x", mac[i]);
    strlcat(msg, "\n", sizeof msg);
    if (!conn_send(fd, msg)) return false;

    // Mac 这时启动 Steam 会话并读取成就，可能要十几秒 | The Mac now starts a Steam session and reads the achievements, which can take over ten seconds
    if (conn_readline(&c, line, sizeof line, 30000) != 1) return false;
    if (strcmp(line, "OK") != 0) {
        relay_log("the Mac refused the session: %s", line);
        return false;
    }
    if (conn_readline(&c, line, sizeof line, 10000) != 1 || strcmp(line, "STATE BEGIN") != 0) return false;
    static char state[32768];
    size_t n = 0;
    state[0] = 0;
    for (;;) {
        if (conn_readline(&c, line, sizeof line, 10000) != 1) return false;
        if (!strcmp(line, "STATE END")) break;
        if (n + strlen(line) + 2 < sizeof state) n += (size_t)snprintf(state + n, sizeof state - n, "%s\n", line);
    }
    pthread_mutex_lock(&g_lock);
    write_file_atomically(g_state_path, state);
    load_state();
    prune_pending();
    int on_steam = 0;
    for (int i = 0; i < g_nach; i++) on_steam += g_ach[i].steam;
    for (int k = 0; k < g_npend; k++) g_pend[k].sent = false;
    int waiting = g_npend;
    pthread_mutex_unlock(&g_lock);
    relay_log("connected to the Mac: %d achievements unlocked on Steam, %d entries to send", on_steam, waiting);

    time_t last_tx = time(NULL), last_rx = time(NULL);
    for (;;) {
        static char out[MAX_PENDING * 96];
        size_t olen = 0;
        pthread_mutex_lock(&g_lock);
        for (int k = 0; k < g_npend && olen < sizeof out - 96; k++) {
            Pending *p = &g_pend[k];
            if (p->sent) continue;
            if (p->kind == 'A') olen += (size_t)snprintf(out + olen, sizeof out - olen, "SET %ld A %s\n", p->id, p->name);
            else olen += (size_t)snprintf(out + olen, sizeof out - olen, "SET %ld %c %s %.17g\n", p->id, p->kind, p->name, p->value);
            p->sent = true;
        }
        pthread_mutex_unlock(&g_lock);
        if (olen) {
            if (!conn_send(fd, out)) return true;
            last_tx = time(NULL);
        }
        int r = conn_readline(&c, line, sizeof line, 1000);
        if (r < 0) {
            relay_log("the connection to the Mac closed");
            return true;
        }
        time_t now = time(NULL);
        if (r == 1) {
            last_rx = now;
            if (!strncmp(line, "ACK ", 4)) ack_pending(atol(line + 4), true);
            else if (!strncmp(line, "NAK ", 4)) {
                char *end = NULL;
                long id = strtol(line + 4, &end, 10);
                if (end && !strcmp(end, " unknown")) ack_pending(id, false);
            } else if (!strncmp(line, "ERR ", 4)) {
                relay_log("the Mac reported: %s", line + 4);
                return true;
            }
        }
        if (now - last_tx >= 20) {
            if (!conn_send(fd, "PING\n")) return true;
            last_tx = now;
        }
        if (now - last_rx >= 75) {
            relay_log("the Mac stopped answering");
            return true;
        }
    }
}

static void relay_wait(int seconds)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += seconds;
    pthread_mutex_lock(&g_lock);
    pthread_cond_timedwait(&g_wake, &g_lock, &ts);
    pthread_mutex_unlock(&g_lock);
}

static void *relay_thread(void *arg)
{
    (void)arg;
    int backoff = 5;
    bool quiet = false;  // 连续失败时只记第一次 | Log only the first of consecutive failures
    for (;;) {
        // make achievements-sync 可能在 App 运行时写入了新的 state.txt | make achievements-sync may have written a new state.txt while the app runs
        struct stat st;
        if (stat(g_state_path, &st) == 0 && st.st_mtime != g_state_mtime) {
            pthread_mutex_lock(&g_lock);
            load_state();
            prune_pending();
            pthread_mutex_unlock(&g_lock);
        }
        int fd = relay_connect(quiet);
        bool ok = false;
        if (fd >= 0) {
            ok = relay_session(fd);
            close(fd);
        }
        quiet = !ok;
        backoff = ok ? 5 : (backoff < 60 ? backoff * 2 : 60);
        relay_wait(backoff);
    }
    return NULL;
}

static void relay_setup(void)
{
    const char *home = getenv("HOME");
    snprintf(g_dir, sizeof g_dir, "%s/Documents/Achievements", home ? home : ".");
    snprintf(g_state_path, sizeof g_state_path, "%s/state.txt", g_dir);
    snprintf(g_pending_path, sizeof g_pending_path, "%s/pending.txt", g_dir);
    mkdir(g_dir, 0755);
    pthread_mutex_lock(&g_lock);
    load_state();
    load_pending();
    prune_pending();
    if (!g_lang[0]) default_language();
    if (!g_langs[0]) snprintf(g_langs, sizeof g_langs, "english,%s", g_lang);
    int on_steam = 0;
    for (int i = 0; i < g_nach; i++) on_steam += g_ach[i].steam;
    int waiting = g_npend;
    pthread_mutex_unlock(&g_lock);
    bool networked = sizeof(DE_RELAY_HOST) > 1 && sizeof(DE_RELAY_SECRET) > 1;
    relay_log("mode on: %d achievements known unlocked on Steam, %d entries waiting; relay %s%s%s", on_steam, waiting,
              networked ? DE_RELAY_HOST : "off (make achievements-sync only)", networked ? ":" : "", networked ? DE_RELAY_PORT : "");
    if (networked) {
        pthread_t t;
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
        pthread_create(&t, &attr, relay_thread, NULL);
        pthread_attr_destroy(&attr);
    }
}

static void relay_start(void)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, relay_setup);
}

// ---- 生命周期 | Lifecycle ----

// override: SteamAPI_RestartAppIfNecessary
DE_EXPORT bool SteamAPI_RestartAppIfNecessary(uint32_t appId)
{
    (void)appId;
    return false;
}

// override: SteamAPI_Init
DE_EXPORT bool SteamAPI_Init(void)
{
    relay_start();
    return true;
}

// override: SteamAPI_InitSafe
DE_EXPORT bool SteamAPI_InitSafe(void)
{
    relay_start();
    return true;
}

// 新版 SDK 的初始化入口，0 表示成功 | The newer SDK's init entry point; 0 means success
// override: SteamInternal_SteamAPI_Init
DE_EXPORT int SteamInternal_SteamAPI_Init(const char *versions, char *errMsg)
{
    (void)versions;
    if (errMsg) errMsg[0] = 0;
    relay_start();
    return 0;
}

// override: SteamAPI_IsSteamRunning
DE_EXPORT bool SteamAPI_IsSteamRunning(void)
{
    return true;
}

// 游戏退出时调用；记录都已经写在文件里，转发线程随进程结束 | Called when the game quits; every entry is already on disk and the relay thread ends with the process
// override: SteamAPI_Shutdown
DE_EXPORT void SteamAPI_Shutdown(void)
{
}

// override: SteamAPI_GetHSteamUser
DE_EXPORT int32_t SteamAPI_GetHSteamUser(void)
{
    return 1;
}

// override: SteamAPI_GetHSteamPipe
DE_EXPORT int32_t SteamAPI_GetHSteamPipe(void)
{
    return 1;
}

// ---- 接口指针（Steamworks.NET 的 CSteamAPIContext.Init 要求全部不为空） ----
// ---- Interface pointers (Steamworks.NET's CSteamAPIContext.Init requires all of them to be non-NULL) ----

// override: SteamInternal_CreateInterface
DE_EXPORT void *SteamInternal_CreateInterface(const char *version)
{
    (void)version;
    return g_iface;
}

// override: SteamInternal_FindOrCreateUserInterface
DE_EXPORT void *SteamInternal_FindOrCreateUserInterface(int32_t user, const char *version)
{
    (void)user;
    (void)version;
    return g_iface;
}

#define DE_IFACE_GETTER(fn)                                                                  \
    DE_EXPORT void *fn(void *client, int32_t user, int32_t pipe, const char *version)        \
    {                                                                                        \
        (void)client; (void)user; (void)pipe; (void)version;                                 \
        return g_iface;                                                                      \
    }
// override: SteamAPI_ISteamClient_GetISteamAppList
DE_IFACE_GETTER(SteamAPI_ISteamClient_GetISteamAppList)
// override: SteamAPI_ISteamClient_GetISteamApps
DE_IFACE_GETTER(SteamAPI_ISteamClient_GetISteamApps)
// override: SteamAPI_ISteamClient_GetISteamFriends
DE_IFACE_GETTER(SteamAPI_ISteamClient_GetISteamFriends)
// override: SteamAPI_ISteamClient_GetISteamGameSearch
DE_IFACE_GETTER(SteamAPI_ISteamClient_GetISteamGameSearch)
// override: SteamAPI_ISteamClient_GetISteamHTMLSurface
DE_IFACE_GETTER(SteamAPI_ISteamClient_GetISteamHTMLSurface)
// override: SteamAPI_ISteamClient_GetISteamHTTP
DE_IFACE_GETTER(SteamAPI_ISteamClient_GetISteamHTTP)
// override: SteamAPI_ISteamClient_GetISteamInput
DE_IFACE_GETTER(SteamAPI_ISteamClient_GetISteamInput)
// override: SteamAPI_ISteamClient_GetISteamInventory
DE_IFACE_GETTER(SteamAPI_ISteamClient_GetISteamInventory)
// override: SteamAPI_ISteamClient_GetISteamMatchmaking
DE_IFACE_GETTER(SteamAPI_ISteamClient_GetISteamMatchmaking)
// override: SteamAPI_ISteamClient_GetISteamMatchmakingServers
DE_IFACE_GETTER(SteamAPI_ISteamClient_GetISteamMatchmakingServers)
// override: SteamAPI_ISteamClient_GetISteamMusic
DE_IFACE_GETTER(SteamAPI_ISteamClient_GetISteamMusic)
// override: SteamAPI_ISteamClient_GetISteamMusicRemote
DE_IFACE_GETTER(SteamAPI_ISteamClient_GetISteamMusicRemote)
// override: SteamAPI_ISteamClient_GetISteamNetworking
DE_IFACE_GETTER(SteamAPI_ISteamClient_GetISteamNetworking)
// override: SteamAPI_ISteamClient_GetISteamParentalSettings
DE_IFACE_GETTER(SteamAPI_ISteamClient_GetISteamParentalSettings)
// override: SteamAPI_ISteamClient_GetISteamParties
DE_IFACE_GETTER(SteamAPI_ISteamClient_GetISteamParties)
// override: SteamAPI_ISteamClient_GetISteamRemotePlay
DE_IFACE_GETTER(SteamAPI_ISteamClient_GetISteamRemotePlay)
// override: SteamAPI_ISteamClient_GetISteamRemoteStorage
DE_IFACE_GETTER(SteamAPI_ISteamClient_GetISteamRemoteStorage)
// override: SteamAPI_ISteamClient_GetISteamScreenshots
DE_IFACE_GETTER(SteamAPI_ISteamClient_GetISteamScreenshots)
// override: SteamAPI_ISteamClient_GetISteamUGC
DE_IFACE_GETTER(SteamAPI_ISteamClient_GetISteamUGC)
// override: SteamAPI_ISteamClient_GetISteamUser
DE_IFACE_GETTER(SteamAPI_ISteamClient_GetISteamUser)
// override: SteamAPI_ISteamClient_GetISteamUserStats
DE_IFACE_GETTER(SteamAPI_ISteamClient_GetISteamUserStats)
// override: SteamAPI_ISteamClient_GetISteamUtils
DE_IFACE_GETTER(SteamAPI_ISteamClient_GetISteamUtils)
// override: SteamAPI_ISteamClient_GetISteamVideo
DE_IFACE_GETTER(SteamAPI_ISteamClient_GetISteamVideo)

// ---- 回调分发（Steamworks.NET 用 ManualDispatch 每帧取回调） ----
// ---- Callback dispatch (Steamworks.NET fetches callbacks every frame through ManualDispatch) ----

// override: SteamAPI_ManualDispatch_Init
DE_EXPORT void SteamAPI_ManualDispatch_Init(void)
{
}

// override: SteamAPI_ManualDispatch_RunFrame
DE_EXPORT void SteamAPI_ManualDispatch_RunFrame(int32_t pipe)
{
    (void)pipe;
}

// override: SteamAPI_ManualDispatch_GetNextCallback
DE_EXPORT bool SteamAPI_ManualDispatch_GetNextCallback(int32_t pipe, CallbackMsg *msg)
{
    (void)pipe;
    bool ok = false;
    pthread_mutex_lock(&g_lock);
    if (g_cb_count > 0 && msg) {
        g_cb_current = g_cb[g_cb_head];
        g_cb_head = (g_cb_head + 1) % MAX_CALLBACKS;
        g_cb_count--;
        msg->user = 1;
        msg->callback = g_cb_current.id;
        msg->param = g_cb_current.data;
        msg->size = g_cb_current.size;
        ok = true;
    }
    pthread_mutex_unlock(&g_lock);
    return ok;
}

// override: SteamAPI_ManualDispatch_FreeLastCallback
DE_EXPORT void SteamAPI_ManualDispatch_FreeLastCallback(int32_t pipe)
{
    (void)pipe;
}

// override: SteamAPI_ManualDispatch_GetAPICallResult
DE_EXPORT bool SteamAPI_ManualDispatch_GetAPICallResult(int32_t pipe, uint64_t call, void *buf, int32_t size, int32_t expected, bool *failed)
{
    (void)pipe; (void)call; (void)buf; (void)size; (void)expected;
    if (failed) *failed = true;
    return false;
}

// ---- 成就与统计值 | Achievements and stats ----

// 立即用本地记录回答"已读取"；Steam 上的状态由转发线程在连上 Mac 后更新
// Answer "received" at once from the local records; the relay thread updates Steam's state once it reaches the Mac
// override: SteamAPI_ISteamUserStats_RequestCurrentStats
DE_EXPORT bool SteamAPI_ISteamUserStats_RequestCurrentStats(void *self)
{
    (void)self;
    relay_start();
    pthread_mutex_lock(&g_lock);
    UserStatsReceived r = { DE_STEAM_APP_ID, kResultOK, g_steam_id };
    push_callback(kUserStatsReceived, &r, sizeof r);
    pthread_mutex_unlock(&g_lock);
    return true;
}

// override: SteamAPI_ISteamUserStats_GetAchievement
DE_EXPORT bool SteamAPI_ISteamUserStats_GetAchievement(void *self, const char *name, bool *achieved)
{
    (void)self;
    if (!valid_name(name)) return false;
    pthread_mutex_lock(&g_lock);
    int i = ach_index(name, false);
    if (achieved) *achieved = i >= 0 && (g_ach[i].steam || g_ach[i].local);
    pthread_mutex_unlock(&g_lock);
    return true;
}

// override: SteamAPI_ISteamUserStats_SetAchievement
DE_EXPORT bool SteamAPI_ISteamUserStats_SetAchievement(void *self, const char *name)
{
    (void)self;
    if (!valid_name(name)) return false;
    pthread_mutex_lock(&g_lock);
    int i = ach_index(name, true);
    bool fresh = i >= 0 && !g_ach[i].steam && !g_ach[i].local;
    if (fresh) {
        g_ach[i].local = true;
        add_pending('A', name, 0);
        if (g_nnewly < 16) strlcpy(g_newly[g_nnewly++], name, MAX_NAME);
    }
    pthread_mutex_unlock(&g_lock);
    if (fresh) relay_log("achievement %s recorded", name);
    return i >= 0;
}

// override: SteamAPI_ISteamUserStats_ClearAchievement
DE_EXPORT bool SteamAPI_ISteamUserStats_ClearAchievement(void *self, const char *name)
{
    (void)self;
    relay_log("ClearAchievement(%s) ignored: commits go to Steam one way only", name ? name : "");
    return true;
}

// override: SteamAPI_ISteamUserStats_ResetAllStats
DE_EXPORT bool SteamAPI_ISteamUserStats_ResetAllStats(void *self, bool achievementsToo)
{
    (void)self;
    relay_log("ResetAllStats(%d) ignored: commits go to Steam one way only", achievementsToo);
    return true;
}

// override: SteamAPI_ISteamUserStats_GetStatInt32
DE_EXPORT bool SteamAPI_ISteamUserStats_GetStatInt32(void *self, const char *name, int32_t *data)
{
    (void)self;
    if (!valid_name(name)) return false;
    pthread_mutex_lock(&g_lock);
    int i = stat_index(name, 'I', false);
    if (data) *data = i < 0 ? 0 : (int32_t)(g_stat[i].has_local ? g_stat[i].local : g_stat[i].steam);
    pthread_mutex_unlock(&g_lock);
    return true;
}

// override: SteamAPI_ISteamUserStats_GetStatFloat
DE_EXPORT bool SteamAPI_ISteamUserStats_GetStatFloat(void *self, const char *name, float *data)
{
    (void)self;
    if (!valid_name(name)) return false;
    pthread_mutex_lock(&g_lock);
    int i = stat_index(name, 'F', false);
    if (data) *data = i < 0 ? 0.0f : (float)(g_stat[i].has_local ? g_stat[i].local : g_stat[i].steam);
    pthread_mutex_unlock(&g_lock);
    return true;
}

static bool set_stat(const char *name, char kind, double value)
{
    if (!valid_name(name)) return false;
    pthread_mutex_lock(&g_lock);
    int i = stat_index(name, kind, true);
    bool changed = i >= 0 && !(g_stat[i].has_local ? g_stat[i].local == value : (g_stat[i].has_steam && g_stat[i].steam == value));
    if (changed) {
        g_stat[i].has_local = true;
        g_stat[i].local = value;
        add_pending(kind, name, value);
    }
    pthread_mutex_unlock(&g_lock);
    return i >= 0;
}

// override: SteamAPI_ISteamUserStats_SetStatInt32
DE_EXPORT bool SteamAPI_ISteamUserStats_SetStatInt32(void *self, const char *name, int32_t data)
{
    (void)self;
    return set_stat(name, 'I', data);
}

// override: SteamAPI_ISteamUserStats_SetStatFloat
DE_EXPORT bool SteamAPI_ISteamUserStats_SetStatFloat(void *self, const char *name, float data)
{
    (void)self;
    return set_stat(name, 'F', data);
}

// 和真 Steam 一样回报"已保存"，并唤醒转发线程立即发送 | Report "stored" as the real Steam does, and wake the relay thread to send at once
// override: SteamAPI_ISteamUserStats_StoreStats
DE_EXPORT bool SteamAPI_ISteamUserStats_StoreStats(void *self)
{
    (void)self;
    pthread_mutex_lock(&g_lock);
    UserStatsStored s = { DE_STEAM_APP_ID, kResultOK };
    push_callback(kUserStatsStored, &s, sizeof s);
    for (int k = 0; k < g_nnewly; k++) {
        UserAchievementStored a;
        memset(&a, 0, sizeof a);
        a.gameID = DE_STEAM_APP_ID;
        strlcpy(a.name, g_newly[k], sizeof a.name);
        push_callback(kUserAchievementStored, &a, sizeof a);
    }
    g_nnewly = 0;
    pthread_cond_signal(&g_wake);
    pthread_mutex_unlock(&g_lock);
    return true;
}

// ---- 用户、语言、设备 | User, language, device ----

// override: SteamAPI_ISteamUser_GetSteamID
DE_EXPORT uint64_t SteamAPI_ISteamUser_GetSteamID(void *self)
{
    (void)self;
    return g_steam_id;
}

// override: SteamAPI_ISteamFriends_GetPersonaName
DE_EXPORT const char *SteamAPI_ISteamFriends_GetPersonaName(void *self)
{
    (void)self;
    return g_persona;
}

// override: SteamAPI_ISteamApps_GetCurrentGameLanguage
DE_EXPORT const char *SteamAPI_ISteamApps_GetCurrentGameLanguage(void *self)
{
    (void)self;
    static int logged;
    if (!logged) { logged = 1; relay_log("game language reported to the game: %s", g_lang); }
    return g_lang;
}

// override: SteamAPI_ISteamApps_GetAvailableGameLanguages
DE_EXPORT const char *SteamAPI_ISteamApps_GetAvailableGameLanguages(void *self)
{
    (void)self;
    return g_langs;
}

// override: SteamAPI_ISteamUtils_IsSteamRunningOnSteamDeck
DE_EXPORT bool SteamAPI_ISteamUtils_IsSteamRunningOnSteamDeck(void *self)
{
    (void)self;
    return false;
}
