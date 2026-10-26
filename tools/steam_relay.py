#!/usr/bin/env python3
"""Mac 端的 Steam 成就工具：通过这台 Mac 上正在运行、已登录的 Steam 客户端读写成就。

只用你游戏目录里正版的 libsteam_api.dylib 和官方 Steamworks 接口；是否拥有这款游戏由 Steam 客户端自己校验。
运行时需要 Steam 已打开并登录。用 macOS 自带的 /usr/bin/python3 运行（scripts/achievements.sh 会这样做），
它兼容 Python 3.9，只用标准库。

子命令：
  list                          列出全部成就和解锁状态（只读）
  unlock [--yes] <成就 ID>...    手动解锁（默认先确认）
  sync <pending.txt> <state.txt> 应用 iPad 记下的成就（USB 同步），再写出 Steam 上的最新状态
  serve [--dry-run]             等 iPad 通过本地网络连上来，实时转发成就（--dry-run 只记日志，不解锁）
  worker <fd> [--dry-run]       （内部）serve 为每个连接启动的会话进程

由 scripts/achievements.sh 通过环境变量传入配置：
  DE_STEAM_LIB      libsteam_api.dylib 的路径
  DE_STEAM_APP_ID   游戏的 Steam App ID
  DE_RELAY_PORT     serve 监听的端口
  DE_RELAY_SECRET   与 iPad 共用的配对密钥（十六进制）

Steam achievement tool for the Mac: reads and writes achievements through the Steam client that is running and
logged in on this Mac.

It uses only the genuine libsteam_api.dylib from your game folder and the official Steamworks interface; the Steam
client itself checks that you own the game. Steam must be open and logged in. Run it with macOS's own
/usr/bin/python3 (scripts/achievements.sh does); it is compatible with Python 3.9 and uses only the standard library.

Subcommands:
  list                          list every achievement and whether it is unlocked (read-only)
  unlock [--yes] <id>...        unlock by hand (asks for confirmation unless --yes)
  sync <pending.txt> <state.txt> apply the achievements recorded on the iPad (USB sync), then write Steam's current state
  serve [--dry-run]             wait for the iPad to connect over the local network and forward achievements live
                                (--dry-run only logs, it unlocks nothing)
  worker <fd> [--dry-run]       (internal) the session process serve starts for each connection

scripts/achievements.sh passes the configuration in environment variables:
  DE_STEAM_LIB      path of libsteam_api.dylib
  DE_STEAM_APP_ID   the game's Steam app ID
  DE_RELAY_PORT     the port serve listens on
  DE_RELAY_SECRET   the pairing secret shared with the iPad (hex)
"""
import ctypes
import hmac
import os
import re
import secrets
import select
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time

PROTOCOL = "DE-STEAM-RELAY 1"
K_USER_STATS_RECEIVED = 1101
K_USER_STATS_STORED = 1102
K_RESULT_OK = 1
NAME_RE = re.compile(r"[A-Za-z0-9_.-]{1,63}")
IDLE_TIMEOUT = 90  # iPad 每 20 秒发一次 PING；这么久没消息就结束会话 | The iPad sends PING every 20 s; end the session after this long without a message


def m(zh, en):
    """按 DE_LANG / 系统语言选择输出语言 | Pick the output language from DE_LANG / the system language"""
    lang = os.environ.get("DE_LANG") or os.environ.get("LC_ALL") or os.environ.get("LANG") or ""
    return zh if lang.startswith("zh") else en


def log(msg):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), msg, flush=True)


def env(name):
    value = os.environ.get(name, "")
    if not value:
        sys.exit(m("缺少环境变量 %s（请通过 scripts/achievements.sh 运行）", "Missing environment variable %s (run this through scripts/achievements.sh)") % name)
    return value


class SteamError(Exception):
    pass


class CallbackMsg(ctypes.Structure):
    # CallbackMsg_t；macOS 版 Steamworks 的回调结构按 4 字节对齐
    # CallbackMsg_t; the macOS Steamworks callback structures are packed to 4 bytes
    _pack_ = 4
    _fields_ = [("user", ctypes.c_int32), ("id", ctypes.c_int32),
                ("param", ctypes.c_void_p), ("size", ctypes.c_int32)]


class Steam:
    """一次 Steam 会话：初始化、读取成就与统计值、写入、结束 | One Steam session: initialize, read achievements and stats, write, shut down"""

    def __init__(self, lib_path, app_id):
        self.app_id = int(app_id)
        # SteamAPI_Init 从环境变量或当前目录的 steam_appid.txt 得知是哪个游戏
        # SteamAPI_Init learns which game this is from the environment or from steam_appid.txt in the current directory
        work = tempfile.mkdtemp(prefix="de-steam-")
        with open(os.path.join(work, "steam_appid.txt"), "w") as f:
            f.write(str(self.app_id))
        os.chdir(work)
        os.environ["SteamAppId"] = os.environ["SteamGameId"] = str(self.app_id)

        try:
            lib = ctypes.CDLL(lib_path)
        except OSError:
            raise SteamError(m("无法加载 libsteam_api.dylib（%s）。在 Steam 里重新安装 Mac 版游戏，然后运行 make relay-install，它会保留一份副本",
                               "Cannot load libsteam_api.dylib (%s). Reinstall the Mac version of the game in Steam, then run make relay-install; it keeps a copy") % lib_path)
        P, B, S = ctypes.c_void_p, ctypes.c_bool, ctypes.c_char_p
        I32, U32, U64, F = ctypes.c_int32, ctypes.c_uint32, ctypes.c_uint64, ctypes.c_float

        def fn(name, res, *args):
            try:
                f = getattr(lib, name)
            except AttributeError:
                raise SteamError(m("这个版本的 libsteam_api 没有 %s", "This libsteam_api version has no %s") % name)
            f.restype = res
            f.argtypes = list(args)
            return f

        init = fn("SteamAPI_Init", B)
        self._shutdown = fn("SteamAPI_Shutdown", None)
        if not init():
            raise SteamError(m("Steam 初始化失败：请先打开 Steam 并登录拥有这款游戏的账号",
                               "Steam initialization failed: open Steam and log in with the account that owns the game"))
        self._alive = True
        fn("SteamAPI_ManualDispatch_Init", None)()
        self._pipe = fn("SteamAPI_GetHSteamPipe", I32)()
        self._run_frame = fn("SteamAPI_ManualDispatch_RunFrame", None, I32)
        self._next = fn("SteamAPI_ManualDispatch_GetNextCallback", B, I32, ctypes.POINTER(CallbackMsg))
        self._free = fn("SteamAPI_ManualDispatch_FreeLastCallback", None, I32)

        self._us = fn("SteamAPI_SteamUserStats_v012", P)()
        user = fn("SteamAPI_SteamUser_v021", P)()
        friends = fn("SteamAPI_SteamFriends_v017", P)()
        apps = fn("SteamAPI_SteamApps_v008", P)()
        if not (self._us and user and friends and apps):
            raise SteamError(m("这个版本的 libsteam_api 缺少需要的接口", "This libsteam_api version lacks a required interface"))

        self._num = fn("SteamAPI_ISteamUserStats_GetNumAchievements", U32, P)
        self._name = fn("SteamAPI_ISteamUserStats_GetAchievementName", S, P, U32)
        self._get_time = fn("SteamAPI_ISteamUserStats_GetAchievementAndUnlockTime", B, P, S,
                            ctypes.POINTER(B), ctypes.POINTER(U32))
        self._attr = fn("SteamAPI_ISteamUserStats_GetAchievementDisplayAttribute", S, P, S, S)
        self._set = fn("SteamAPI_ISteamUserStats_SetAchievement", B, P, S)
        self._get_i = fn("SteamAPI_ISteamUserStats_GetStatInt32", B, P, S, ctypes.POINTER(I32))
        self._get_f = fn("SteamAPI_ISteamUserStats_GetStatFloat", B, P, S, ctypes.POINTER(F))
        self._set_i = fn("SteamAPI_ISteamUserStats_SetStatInt32", B, P, S, I32)
        self._set_f = fn("SteamAPI_ISteamUserStats_SetStatFloat", B, P, S, F)
        self._store = fn("SteamAPI_ISteamUserStats_StoreStats", B, P)
        request = fn("SteamAPI_ISteamUserStats_RequestCurrentStats", B, P)

        self.steam_id = fn("SteamAPI_ISteamUser_GetSteamID", U64, P)(user)
        self.persona = (fn("SteamAPI_ISteamFriends_GetPersonaName", S, P)(friends) or b"").decode("utf-8", "replace")
        self.language = (fn("SteamAPI_ISteamApps_GetCurrentGameLanguage", S, P)(apps) or b"").decode()
        self.languages = (fn("SteamAPI_ISteamApps_GetAvailableGameLanguages", S, P)(apps) or b"").decode()

        if not request(self._us):
            raise SteamError(m("RequestCurrentStats 失败", "RequestCurrentStats failed"))
        data = self.wait(K_USER_STATS_RECEIVED, 20)
        game_id, result = struct.unpack_from("<Qi", data, 0)
        if result != K_RESULT_OK:
            raise SteamError(m("读取成就失败（EResult %d）", "Reading the achievements failed (EResult %d)") % result)
        self.stat_types = read_stat_schema(self.app_id)

    def close(self):
        if self._alive:
            self._alive = False
            self._shutdown()

    def pump(self):
        """处理 Steam 回调，返回 [(回调编号, 数据)] | Run Steam callbacks and return [(callback id, data)]"""
        self._run_frame(self._pipe)
        out = []
        msg = CallbackMsg()
        while self._next(self._pipe, ctypes.byref(msg)):
            data = ctypes.string_at(msg.param, msg.size) if msg.param and msg.size > 0 else b""
            out.append((msg.id, data))
            self._free(self._pipe)
        return out

    def wait(self, callback_id, timeout):
        end = time.time() + timeout
        while time.time() < end:
            for cid, data in self.pump():
                if cid == callback_id:
                    return data
            time.sleep(0.05)
        raise SteamError(m("等待 Steam 回调 %d 超时", "Timed out waiting for Steam callback %d") % callback_id)

    def achievements(self):
        """[(ID, 已解锁, 解锁时间, 显示名)] | [(id, unlocked, unlock time, display name)]"""
        out = []
        for i in range(self._num(self._us)):
            name = self._name(self._us, i)
            done, when = ctypes.c_bool(), ctypes.c_uint32()
            self._get_time(self._us, name, ctypes.byref(done), ctypes.byref(when))
            title = (self._attr(self._us, name, b"name") or b"").decode("utf-8", "replace")
            out.append((name.decode(), done.value, when.value, title))
        return out

    def stats(self):
        """[(名称, 'I' 或 'F', 值)]，名称来自 Steam 缓存的统计值定义 | [(name, 'I' or 'F', value)]; names come from Steam's cached stats schema"""
        out = []
        for name, kind in self.stat_types.items():
            if kind == "I":
                v = ctypes.c_int32()
                if self._get_i(self._us, name.encode(), ctypes.byref(v)):
                    out.append((name, kind, v.value))
            else:
                v = ctypes.c_float()
                if self._get_f(self._us, name.encode(), ctypes.byref(v)):
                    out.append((name, kind, v.value))
        return out

    def set_achievement(self, name):
        return bool(self._set(self._us, name.encode()))

    def set_stat(self, kind, name, value):
        if kind == "I":
            return bool(self._set_i(self._us, name.encode(), int(value)))
        return bool(self._set_f(self._us, name.encode(), float(value)))

    def store(self):
        """提交到 Steam 服务器并等待确认 | Commit to the Steam servers and wait for the confirmation"""
        if not self._store(self._us):
            raise SteamError(m("StoreStats 失败", "StoreStats failed"))
        data = self.wait(K_USER_STATS_STORED, 15)
        game_id, result = struct.unpack_from("<Qi", data, 0)
        if result != K_RESULT_OK:
            raise SteamError(m("Steam 拒绝了这次提交（EResult %d）", "Steam rejected the commit (EResult %d)") % result)

    def state_lines(self):
        """iPad 用的状态行（与 Documents/Achievements/state.txt 同格式） | State lines for the iPad (same format as Documents/Achievements/state.txt)"""
        lines = ["A %s %d" % (name, 1 if done else 0) for name, done, _, _ in self.achievements()]
        for name, kind, value in self.stats():
            lines.append("%s %s %s" % (kind, name, value if kind == "I" else repr(float(value))))
        lines += ["P " + self.persona.replace("\n", " "), "D %d" % self.steam_id,
                  "L " + self.language, "G " + self.languages]
        return lines


def read_stat_schema(app_id):
    """从 Steam 缓存的 UserGameStatsSchema_<appid>.bin 读出统计值名称和类型 | Read stat names and types from Steam's cached UserGameStatsSchema_<appid>.bin"""
    path = os.path.expanduser("~/Library/Application Support/Steam/appcache/stats/UserGameStatsSchema_%d.bin" % app_id)
    try:
        data = open(path, "rb").read()
        root, _ = parse_binary_kv(data, 0)
    except (OSError, ValueError, IndexError, struct.error):
        return {}
    types = {}
    for app in root.values():
        if not isinstance(app, dict):
            continue
        for stat in (app.get("stats") or {}).values():
            if not isinstance(stat, dict):
                continue
            kind = {1: "INT", 2: "FLOAT", 3: "AVGRATE"}.get(stat.get("type"), stat.get("type"))
            name = stat.get("name")
            if isinstance(name, str) and kind in ("INT", "FLOAT", "AVGRATE"):
                types[name] = "I" if kind == "INT" else "F"
    return types


def parse_binary_kv(b, i):
    """Valve 二进制 KeyValues：类型字节、以 0 结尾的键、值；8 表示一层结束 | Valve binary KeyValues: type byte, NUL-terminated key, value; 8 ends a level"""
    d = {}
    while True:
        t = b[i]
        i += 1
        if t == 8:
            return d, i
        j = b.index(0, i)
        key = b[i:j].decode("utf-8", "replace")
        i = j + 1
        if t == 0:
            value, i = parse_binary_kv(b, i)
        elif t == 1:
            j = b.index(0, i)
            value = b[i:j].decode("utf-8", "replace")
            i = j + 1
        elif t == 2:
            value = struct.unpack_from("<i", b, i)[0]
            i += 4
        elif t == 3:
            value = struct.unpack_from("<f", b, i)[0]
            i += 4
        elif t == 7:
            value = struct.unpack_from("<Q", b, i)[0]
            i += 8
        else:
            raise ValueError("binary KeyValues type %d" % t)
        d[key] = value


def open_steam():
    try:
        return Steam(env("DE_STEAM_LIB"), env("DE_STEAM_APP_ID"))
    except SteamError as e:
        sys.exit(str(e))


# ---- list / unlock / sync ----

def cmd_list(args):
    steam = open_steam()
    try:
        rows = steam.achievements()
    finally:
        steam.close()
    done = 0
    for name, unlocked, when, title in rows:
        stamp = time.strftime("%Y-%m-%d %H:%M", time.localtime(when)) if unlocked and when else ""
        print("%s %-16s %-24s %s" % ("✓" if unlocked else "·", stamp, name, title))
        done += unlocked
    print(m("已解锁 %d / %d", "Unlocked %d of %d") % (done, len(rows)))


def cmd_unlock(args):
    yes = "--yes" in args
    names = [a for a in args if a != "--yes"]
    if not names:
        sys.exit(m("用法：unlock [--yes] <成就 ID>...", "Usage: unlock [--yes] <achievement id>..."))
    steam = open_steam()
    try:
        rows = {name: (unlocked, title) for name, unlocked, _, title in steam.achievements()}
        unknown = [n for n in names if n not in rows]
        if unknown:
            sys.exit(m("没有这些成就：%s（make achievements 列出全部 ID）", "No such achievements: %s (make achievements lists every id)")
                     % " ".join(unknown))
        todo = [n for n in names if not rows[n][0]]
        for n in names:
            if rows[n][0]:
                print(m("已经解锁：%s %s", "Already unlocked: %s %s") % (n, rows[n][1]))
        if not todo:
            return
        for n in todo:
            print(m("将解锁：%s %s", "Will unlock: %s %s") % (n, rows[n][1]))
        if not yes:
            answer = input(m("在你的 Steam 账号上解锁以上 %d 个成就？[y/N] ", "Unlock these %d achievements on your Steam account? [y/N] ") % len(todo))
            if answer.strip().lower() not in ("y", "yes"):
                print(m("已取消", "Cancelled"))
                return
        for n in todo:
            steam.set_achievement(n)
        steam.store()
        print(m("完成：已在 Steam 上解锁 %d 个成就", "Done: %d achievements unlocked on Steam") % len(todo))
    finally:
        steam.close()


def read_pending(path):
    """iPad 的 pending.txt：每行 "<编号> <A|I|F> <名称> <值>" | The iPad's pending.txt: one "<id> <A|I|F> <name> <value>" per line"""
    ops = []
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        return ops
    for line in lines:
        parts = line.split()
        if len(parts) == 4 and parts[1] in ("A", "I", "F") and NAME_RE.fullmatch(parts[2]):
            ops.append((parts[0], parts[1], parts[2], parts[3]))
    return ops


def cmd_sync(args):
    if len(args) != 2:
        sys.exit(m("用法：sync <pending.txt> <state.txt>", "Usage: sync <pending.txt> <state.txt>"))
    pending_path, state_path = args
    ops = read_pending(pending_path)
    steam = open_steam()
    try:
        known = {name: unlocked for name, unlocked, _, _ in steam.achievements()}
        applied = 0
        for op_id, kind, name, value in ops:
            if kind == "A":
                if name not in known:
                    print(m("跳过未知成就 %s", "Skipping unknown achievement %s") % name)
                    continue
                if not known[name]:
                    steam.set_achievement(name)
                    print(m("解锁 %s", "Unlocking %s") % name)
                    applied += 1
            elif steam.set_stat(kind, name, value):
                applied += 1
        if applied:
            steam.store()
        lines = steam.state_lines()
    finally:
        steam.close()
    with open(state_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print(m("iPad 记录了 %d 条，这次提交到 Steam %d 条", "The iPad recorded %d entries; %d were committed to Steam this time") % (len(ops), applied))


# ---- serve / worker：本地网络实时转发 | serve / worker: live forwarding over the local network ----
#
# 协议是 UTF-8 文本行：
#   Mac → iPad   HELLO DE-STEAM-RELAY 1 <随机数>
#   iPad → Mac   AUTH <HMAC-SHA256(密钥, 随机数) 的十六进制>
#   Mac → iPad   OK，然后 STATE BEGIN、状态行（同 state.txt）、STATE END；失败时 ERR <原因> 并断开
#   iPad → Mac   SET <编号> A <成就>  |  SET <编号> I|F <统计值> <值>  |  PING
#   Mac → iPad   ACK <编号>（已提交到 Steam）  |  NAK <编号> unknown（Steam 没有这个名字，iPad 丢弃）  |  PONG
# The protocol is UTF-8 text lines:
#   Mac → iPad   HELLO DE-STEAM-RELAY 1 <nonce>
#   iPad → Mac   AUTH <hex of HMAC-SHA256(secret, nonce)>
#   Mac → iPad   OK, then STATE BEGIN, state lines (as in state.txt), STATE END; on failure ERR <reason> and disconnect
#   iPad → Mac   SET <id> A <achievement>  |  SET <id> I|F <stat> <value>  |  PING
#   Mac → iPad   ACK <id> (committed to Steam)  |  NAK <id> unknown (Steam has no such name; the iPad drops it)  |  PONG

def send_line(sock, line):
    sock.sendall((line + "\n").encode("utf-8"))


def recv_line(sock, buf, timeout):
    """读一行；超时返回 None，对方断开时抛出 EOFError | Read one line; returns None on timeout, raises EOFError when the peer disconnects"""
    end = time.time() + timeout
    while b"\n" not in buf:
        left = end - time.time()
        if left <= 0:
            return None
        r, _, _ = select.select([sock], [], [], left)
        if not r:
            return None
        chunk = sock.recv(4096)
        if not chunk:
            raise EOFError
        buf.extend(chunk)
        if len(buf) > 65536:
            raise EOFError
    i = buf.index(b"\n")
    line = bytes(buf[:i]).decode("utf-8", "replace").rstrip("\r")
    del buf[:i + 1]
    return line


def authenticate(sock, secret):
    nonce = secrets.token_hex(16)
    send_line(sock, "HELLO %s %s" % (PROTOCOL, nonce))
    line = recv_line(sock, bytearray(), 10)
    expected = hmac.new(bytes.fromhex(secret), nonce.encode(), "sha256").hexdigest()
    return bool(line and line.startswith("AUTH ") and hmac.compare_digest(line[5:].strip(), expected))


def cmd_serve(args):
    dry_run = "--dry-run" in args
    secret = env("DE_RELAY_SECRET")
    port = int(env("DE_RELAY_PORT"))
    bytes.fromhex(secret)  # 密钥格式不对时直接报错 | Fail early on a malformed secret
    server = socket.create_server(("::", port), family=socket.AF_INET6, dualstack_ipv6=True, reuse_port=False)
    log(m("等待 iPad 连接，端口 %d%s", "Waiting for the iPad on port %d%s") % (port, m("（演练模式：不解锁）", " (dry run: nothing is unlocked)") if dry_run else ""))
    worker = None
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    try:
        while True:
            conn, addr = server.accept()
            peer = addr[0]
            try:
                conn.settimeout(10)
                ok = authenticate(conn, secret)
            except (OSError, EOFError):
                ok = False
            if not ok:
                log(m("拒绝 %s：配对密钥不对", "Rejected %s: wrong pairing secret") % peer)
                try:
                    send_line(conn, "ERR auth")
                except OSError:
                    pass
                conn.close()
                continue
            # 同一时间只有一个 Steam 会话；新连接（通常是 iPad 重连）替换旧的
            # Only one Steam session at a time; a new connection (usually the iPad reconnecting) replaces the old one
            if worker and worker.poll() is None:
                log(m("新连接替换上一个会话", "A new connection replaces the previous session"))
                worker.terminate()
                try:
                    worker.wait(10)
                except subprocess.TimeoutExpired:
                    worker.kill()
            log(m("iPad 已连接：%s", "iPad connected: %s") % peer)
            fd = conn.fileno()
            cmd = [sys.executable, "-I", os.path.abspath(__file__), "worker", str(fd)] + (["--dry-run"] if dry_run else [])
            worker = subprocess.Popen(cmd, pass_fds=[fd])
            conn.close()
    except KeyboardInterrupt:
        pass
    finally:
        if worker and worker.poll() is None:
            worker.terminate()


def cmd_worker(args):
    fd = int(args[0])
    dry_run = "--dry-run" in args
    sock = socket.socket(fileno=fd)
    sock.settimeout(None)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    # 任何初始化失败都要告诉 iPad 原因（它会写进 Player.log），而不是让会话进程直接崩溃断开
    # Any start-up failure is reported to the iPad (which writes it to Player.log) instead of the session process crashing and dropping the connection
    try:
        steam = Steam(env("DE_STEAM_LIB"), env("DE_STEAM_APP_ID"))
    except Exception as e:  # noqa: BLE001
        reason = str(e) if isinstance(e, SteamError) else "%s: %s" % (type(e).__name__, e)
        log(reason)
        try:
            send_line(sock, "ERR steam " + reason.replace("\n", " "))
        except OSError:
            pass
        return
    try:
        known = {name for name, _, _, _ in steam.achievements()}
        send_line(sock, "OK")
        send_line(sock, "STATE BEGIN")
        for line in steam.state_lines():
            send_line(sock, line)
        send_line(sock, "STATE END")
        log(m("Steam 会话开始：%s，%d 个成就", "Steam session started: %s, %d achievements") % (steam.persona, len(known)))
        buf = bytearray()
        last_rx = time.time()
        while True:
            line = recv_line(sock, buf, 0.2)
            steam.pump()
            if line is None:
                if time.time() - last_rx > IDLE_TIMEOUT:
                    log(m("iPad 很久没有消息，结束会话", "No message from the iPad for a long time; ending the session"))
                    return
                continue
            last_rx = time.time()
            # 一次读完已经到达的所有行，合并成一次提交 | Read every line that has arrived and commit them together
            lines = [line]
            while True:
                more = recv_line(sock, buf, 0)
                if more is None:
                    break
                lines.append(more)
            acks = []
            for line in lines:
                parts = line.split()
                if parts == ["PING"]:
                    send_line(sock, "PONG")
                elif len(parts) >= 4 and parts[0] == "SET" and parts[2] in ("A", "I", "F") and NAME_RE.fullmatch(parts[3]):
                    op_id, kind, name = parts[1], parts[2], parts[3]
                    if kind == "A" and name not in known:
                        log(m("未知成就 %s，丢弃", "Unknown achievement %s, dropped") % name)
                        send_line(sock, "NAK %s unknown" % op_id)
                    elif dry_run:
                        log(m("演练：本应提交 %s", "Dry run: would commit %s") % " ".join(parts[2:]))
                    elif kind == "A":
                        steam.set_achievement(name)
                        log(m("解锁 %s", "Unlocking %s") % name)
                        acks.append(op_id)
                    elif len(parts) == 5 and steam.set_stat(kind, name, parts[4]):
                        log(m("统计值 %s = %s", "Stat %s = %s") % (name, parts[4]))
                        acks.append(op_id)
                    else:
                        send_line(sock, "NAK %s unknown" % op_id)
            if acks:
                steam.store()
                for op_id in acks:
                    send_line(sock, "ACK " + op_id)
    except (EOFError, OSError):
        log(m("iPad 断开", "The iPad disconnected"))
    except SteamError as e:
        log(str(e))
    finally:
        steam.close()
        log(m("Steam 会话结束", "Steam session ended"))


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    cmd, args = sys.argv[1], sys.argv[2:]
    handlers = {"list": cmd_list, "unlock": cmd_unlock, "sync": cmd_sync, "serve": cmd_serve, "worker": cmd_worker}
    if cmd not in handlers:
        sys.exit(__doc__)
    handlers[cmd](args)


if __name__ == "__main__":
    main()
