#!/usr/bin/env python3.11
"""Talk to a MartinLogan / Anthem / Paradigm sub over the Pi BLE adapter.

The official app uses Silicon Labs Cable Replacement:
  service  5461b27b-e747-4867-bb63-6d0397e5fb57
  char     e7add780-b042-4876-aae1-112855353cc1  (write + indicate)

Settings ride on that serial stream as ASCII, the same frames that
read the firmware and set Night mode on the Dynamo 10:

  query   NAME?;
  set     NAMEvalue;
  reply   NAMEvalue;    a set may answer with a bare ";"

This helper reads and writes the five settings the Lyrion panel shows:
LMD, VOL, PHA, POL, LPF. It does not send the untyped tokens.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time
from typing import Any, Optional

MAC_HELP = "60:EF:AB:27:65:8A"
SVC_VENDOR = "5461b27b-e747-4867-bb63-6d0397e5fb57"
CHAR_CR = "e7add780-b042-4876-aae1-112855353cc1"
CHAR_NAME = "00002a00-0000-1000-8000-00805f9b34fb"
CHAR_MFR = "00002a29-0000-1000-8000-00805f9b34fb"
SOCK_PATH = "/tmp/lyrion-sub-ble.sock"
PID_PATH = "/tmp/lyrion-sub-ble.pid"
IDLE_S = 2.5

# UI name -> wire token. Choice maps are the ones confirmed for LMD
# and published for the others. Integers travel as decimal text.
FIELDS = {
    "mode": {
        "token": "LMD",
        "to_wire": {"music": "0", "movie": "1", "night": "2"},
        "from_wire": {"0": "music", "1": "movie", "2": "night"},
    },
    "level": {"token": "VOL", "min": -40, "max": 12},
    "phase": {"token": "PHA", "min": 0, "max": 180},
    "polarity": {
        "token": "POL",
        "to_wire": {"normal": "0", "inverted": "1"},
        "from_wire": {"0": "normal", "1": "inverted"},
    },
    "lowpass": {"token": "LPF", "min": 35, "max": 120},
}


def encode_setting(setting: str, value: Any) -> str:
    spec = FIELDS.get(setting or "")
    if not spec:
        raise ValueError("unknown_setting")
    if "to_wire" in spec:
        wire = spec["to_wire"].get(str(value))
        if wire is None:
            raise ValueError("bad_value")
    else:
        try:
            number = int(value)
        except (TypeError, ValueError):
            raise ValueError("bad_value")
        if number < spec["min"] or number > spec["max"]:
            raise ValueError("bad_value")
        wire = str(number)
    return spec["token"] + wire + ";"


def parse_frame(text: str) -> Optional[dict[str, Any]]:
    raw = (text or "").strip().strip("\x00")
    if not raw.endswith(";"):
        return None
    body = raw[:-1]
    if body == "":
        return {"bare": True, "raw": raw}
    for name, spec in FIELDS.items():
        token = spec["token"]
        if body.startswith(token):
            wire = body[len(token):]
            if "from_wire" in spec:
                value = spec["from_wire"].get(wire)
            else:
                try:
                    value = int(wire)
                except ValueError:
                    value = None
                else:
                    if value < spec["min"] or value > spec["max"]:
                        value = None
            if value is None:
                return {"name": name, "token": token, "wire": wire, "raw": raw, "ok": False}
            return {"name": name, "token": token, "wire": wire, "value": value, "raw": raw, "ok": True}
    return {"raw": raw, "ok": False}

def _norm(mac: str) -> str:
    return (mac or "").strip().upper()


def _become_real_user() -> None:
    """Lyrion drops only the effective uid. D-Bus EXTERNAL authenticates the real uid.

    With real uid 0 and effective uid tc, BlueZ rejects the helper before any
    connection to the sub. The permitted capability set is still intact, so the
    helper can raise CAP_SETUID and become the real tc user.
    """
    if os.getuid() == os.geteuid() and os.getgid() == os.getegid():
        return
    machine = os.uname().machine
    numbers = {"aarch64": (90, 91), "x86_64": (125, 126)}.get(machine)
    if numbers is None:
        return
    import ctypes
    libc = ctypes.CDLL(None, use_errno=True)

    class Header(ctypes.Structure):
        _fields_ = [("version", ctypes.c_uint32), ("pid", ctypes.c_int)]

    class Data(ctypes.Structure):
        _fields_ = [
            ("effective", ctypes.c_uint32),
            ("permitted", ctypes.c_uint32),
            ("inheritable", ctypes.c_uint32),
        ]

    header = Header(0x20080522, 0)
    data = (Data * 2)()
    if libc.syscall(numbers[0], ctypes.byref(header), data) != 0:
        return
    data[0].effective |= (1 << 6) | (1 << 7)  # CAP_SETGID, CAP_SETUID
    if libc.syscall(numbers[1], ctypes.byref(header), data) != 0:
        return
    try:
        os.setgid(os.getegid())
        os.setuid(os.geteuid())
    except OSError:
        return

def _decode_bytes(data: bytes) -> str:
    text = data.split(b"\x00", 1)[0].decode("utf-8", "replace").strip()
    return text

def _dbus_disconnect(mac: str) -> float:
    """Ask BlueZ to drop the LE link. Returns seconds until the call returns."""
    path = "/org/bluez/hci0/dev_" + mac.replace(":", "_")
    t0 = time.perf_counter()
    try:
        subprocess.run(
            [
                "dbus-send",
                "--system",
                "--print-reply",
                "--dest=org.bluez",
                path,
                "org.bluez.Device1.Disconnect",
            ],
            capture_output=True,
            text=True,
            timeout=8,
        )
    except Exception:
        pass
    return time.perf_counter() - t0

class Bridge:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.clients: dict[str, Any] = {}
        self.identity: dict[str, dict[str, Any]] = {}
        self.inbox: dict[str, Any] = {}
        self.connected_at: dict[str, float] = {}
        self.idle_timer: dict[str, threading.Timer] = {}
        self.last_disc_s: dict[str, float] = {}
        self.loop = None
        self.thread = None

    def start(self) -> None:
        import asyncio
        from bleak import BleakClient

        self.BleakClient = BleakClient
        self.loop = asyncio.new_event_loop()
        self.thread = threading.Thread(target=self._run_loop, name="sub-ble-loop", daemon=True)
        self.thread.start()
        # wait until loop is running
        for _ in range(50):
            if self.loop.is_running():
                break
            time.sleep(0.02)

    def _run_loop(self) -> None:
        asyncio.set_event_loop(self.loop)
        self.loop.run_forever()

    def _call(self, coro, timeout: float = 20.0):
        import asyncio
        fut = asyncio.run_coroutine_threadsafe(coro, self.loop)
        return fut.result(timeout=timeout)

    async def _connect(self, mac: str) -> dict[str, Any]:
        t0 = time.perf_counter()
        client = self.BleakClient(mac, timeout=18.0)
        await client.connect()
        ident: dict[str, Any] = {
            "address": mac,
            "connected": True,
            "connect_s": round(time.perf_counter() - t0, 3),
        }
        try:
            raw = await client.read_gatt_char(CHAR_NAME)
            ident["gap_name"] = _decode_bytes(bytes(raw))
        except Exception as exc:
            ident["gap_name_error"] = str(exc)
        try:
            raw = await client.read_gatt_char(CHAR_MFR)
            ident["manufacturer"] = _decode_bytes(bytes(raw))
        except Exception as exc:
            ident["manufacturer_error"] = str(exc)
        name = ident.get("gap_name") or ""
        if "|" in name:
            ident["sku"], ident["model"] = [p.strip() for p in name.split("|", 1)]
        elif name:
            ident["model"] = name
        # Indications are the sub's answers. The queue is drained before each frame.
        try:
            import asyncio
            self.inbox[mac] = asyncio.Queue()

            def _on(_sender, data: bytearray) -> None:
                text = bytes(data).decode("ascii", "replace")
                queue = self.inbox.get(mac)
                if queue is None or self.loop is None:
                    return
                self.loop.call_soon_threadsafe(queue.put_nowait, text)

            await client.start_notify(CHAR_CR, _on)
            await asyncio.sleep(0.3)
            ident["subscribed"] = True
        except Exception as exc:
            ident["subscribed"] = False
            ident["subscribe_error"] = str(exc)
        self.clients[mac] = client
        self.identity[mac] = ident
        self.connected_at[mac] = time.time()
        return ident

    async def _disconnect(self, mac: str) -> float:
        import asyncio
        client = self.clients.pop(mac, None)
        t0 = time.perf_counter()
        if client is not None:
            try:
                if getattr(client, "is_connected", False):
                    # Prefer a direct BlueZ Disconnect; bleak's own wait can linger.
                    _dbus_disconnect(mac)
                    try:
                        await asyncio.wait_for(client.disconnect(), timeout=3.0)
                    except Exception:
                        pass
            except Exception:
                _dbus_disconnect(mac)
        else:
            _dbus_disconnect(mac)
        elapsed = time.perf_counter() - t0
        self.last_disc_s[mac] = elapsed
        self.inbox.pop(mac, None)
        return elapsed

    def _connected(self, mac: str) -> bool:
        client = self.clients.get(mac)
        return bool(client and getattr(client, "is_connected", False) and self.identity.get(mac, {}).get("subscribed"))

    async def _ensure(self, mac: str) -> dict[str, Any]:
        if self._connected(mac):
            ident = dict(self.identity.get(mac) or {})
            ident["reused"] = True
            return ident
        ident = await self._connect(mac)
        ident["reused"] = False
        return ident

    def _drain(self, mac: str) -> None:
        queue = self.inbox.get(mac)
        if queue is None:
            return
        while True:
            try:
                queue.get_nowait()
            except Exception:
                return

    async def _collect(self, mac: str, timeout: float) -> Optional[dict[str, Any]]:
        import asyncio
        queue = self.inbox.get(mac)
        if queue is None:
            raise RuntimeError("not_connected")
        buf = ""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            remain = deadline - time.monotonic()
            try:
                buf += await asyncio.wait_for(queue.get(), remain)
            except asyncio.TimeoutError:
                break
            if buf.endswith(";"):
                return parse_frame(buf)
        return None

    async def _frame(self, mac: str, payload: str, timeout: float = 1.8) -> Optional[dict[str, Any]]:
        client = self.clients.get(mac)
        if client is None or self.inbox.get(mac) is None:
            raise RuntimeError("not_connected")
        self._drain(mac)
        await client.write_gatt_char(CHAR_CR, payload.encode("ascii"), response=True)
        return await self._collect(mac, timeout)

    async def _query_token(self, mac: str, token: str) -> Optional[dict[str, Any]]:
        # A set often answers with a bare ";". Skip that leftover and keep the real token.
        parsed = await self._frame(mac, token + "?;")
        deadline = time.monotonic() + 1.8
        while parsed and parsed.get("bare") and time.monotonic() < deadline:
            parsed = await self._collect(mac, deadline - time.monotonic())
        if parsed and parsed.get("token") == token and parsed.get("ok"):
            return parsed
        return None

    async def _read_all(self, mac: str) -> dict[str, Any]:
        ident = await self._ensure(mac)
        if not ident.get("subscribed"):
            return {"ok": False, "error": ident.get("subscribe_error") or "not_subscribed", "connected": False}
        settings: dict[str, Any] = {}
        missing = []
        for name, spec in FIELDS.items():
            parsed = await self._query_token(mac, spec["token"])
            if parsed is None:
                missing.append(name)
            else:
                settings[name] = parsed["value"]
        out = dict(ident)
        out.update({
            "ok": True,
            "connected": True,
            "settings": settings,
            "missing": missing,
            "complete": not missing,
            "settings_readable": not missing,
            "protocol": "cable-replacement-serial",
        })
        return out

    async def _write_one(self, mac: str, setting: str, value: Any) -> dict[str, Any]:
        try:
            payload = encode_setting(setting, value)
        except ValueError as exc:
            return {"ok": False, "error": str(exc), "sent": False}
        ident = await self._ensure(mac)
        if not ident.get("subscribed"):
            return {"ok": False, "error": ident.get("subscribe_error") or "not_subscribed", "sent": False}
        token = FIELDS[setting]["token"]
        await self._frame(mac, payload)
        confirmed = await self._query_token(mac, token)
        if confirmed is None:
            return {"ok": False, "error": "no_readback", "sent": True, "setting": setting}
        return {
            "ok": True,
            "sent": True,
            "setting": setting,
            "value": confirmed["value"],
            "wire": confirmed.get("wire"),
            "connected": True,
        }

    def read_settings(self, mac: str) -> dict[str, Any]:
        mac = _norm(mac)
        self._cancel_idle(mac)
        try:
            return self._call(self._read_all(mac), timeout=28.0)
        except Exception as exc:
            return {"ok": False, "error": type(exc).__name__ + ": " + str(exc), "mac": mac, "connected": False}

    def write_setting(self, mac: str, setting: str, value: Any) -> dict[str, Any]:
        mac = _norm(mac)
        self._cancel_idle(mac)
        already = self._connected(mac)
        try:
            out = self._call(self._write_one(mac, setting, value), timeout=28.0)
        except Exception as exc:
            out = {"ok": False, "error": type(exc).__name__ + ": " + str(exc), "sent": False}
        # A scene write opens the link on its own. The menu already holds it.
        if not already:
            self.release(mac, immediate=False)
        out["mac"] = mac
        return out

    def hold(self, mac: str) -> dict[str, Any]:
        mac = _norm(mac)
        self._cancel_idle(mac)
        with self.lock:
            client = self.clients.get(mac)
            already = bool(client and getattr(client, "is_connected", False))
            if already:
                ident = dict(self.identity.get(mac) or {"address": mac, "connected": True})
                ident["reused"] = True
                ident["held"] = True
                ident["settings_readable"] = False
                return ident
        ident = self._call(self._connect(mac), timeout=20.0)
        ident["reused"] = False
        ident["held"] = True
        ident["settings_readable"] = bool(ident.get("subscribed"))
        ident["protocol"] = "cable-replacement-serial"
        return ident

    def release(self, mac: str, immediate: bool = True) -> dict[str, Any]:
        mac = _norm(mac)
        if not immediate:
            self._arm_idle(mac)
            return {"ok": True, "mac": mac, "deferred_s": IDLE_S, "connected": mac in self.clients}
        self._cancel_idle(mac)
        elapsed = 0.0
        with self.lock:
            need = mac in self.clients
        if need or True:
            elapsed = self._call(self._disconnect(mac), timeout=10.0)
        return {
            "ok": True,
            "mac": mac,
            "connected": False,
            "disconnect_s": round(elapsed, 3),
        }

    def status(self, mac: str) -> dict[str, Any]:
        mac = _norm(mac)
        client = self.clients.get(mac)
        connected = bool(client and getattr(client, "is_connected", False))
        ident = dict(self.identity.get(mac) or {"address": mac})
        ident["connected"] = connected
        ident["held"] = connected
        ident["settings_readable"] = False
        if mac in self.last_disc_s:
            ident["last_disconnect_s"] = round(self.last_disc_s[mac], 3)
        return ident

    def _cancel_idle(self, mac: str) -> None:
        timer = self.idle_timer.pop(mac, None)
        if timer is not None:
            timer.cancel()

    def _arm_idle(self, mac: str) -> None:
        self._cancel_idle(mac)
        def _fire() -> None:
            try:
                self.release(mac, immediate=True)
            except Exception:
                pass
        timer = threading.Timer(IDLE_S, _fire)
        timer.daemon = True
        self.idle_timer[mac] = timer
        timer.start()

BRIDGE: Optional[Bridge] = None

def get_bridge() -> Bridge:
    global BRIDGE
    if BRIDGE is None:
        BRIDGE = Bridge()
        BRIDGE.start()
    return BRIDGE

def handle(req: dict[str, Any]) -> dict[str, Any]:
    cmd = (req.get("cmd") or "").strip().lower()
    mac = _norm(req.get("mac") or "")
    if not mac:
        return {"ok": False, "error": "missing_mac"}
    try:
        br = get_bridge()
        if cmd == "hold":
            out = br.hold(mac)
            out["ok"] = True
            return out
        if cmd == "release":
            return br.release(mac, immediate=bool(req.get("immediate", True)))
        if cmd == "status":
            out = br.status(mac)
            out["ok"] = True
            return out
        if cmd == "read":
            return br.read_settings(mac)
        if cmd == "write":
            return br.write_setting(mac, req.get("setting") or "", req.get("value"))
        return {"ok": False, "error": "unknown_cmd"}
    except Exception as exc:
        return {"ok": False, "error": type(exc).__name__ + ": " + str(exc), "mac": mac}

def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False

def start_daemon() -> None:
    if os.path.exists(PID_PATH):
        try:
            pid = int(open(PID_PATH).read().strip())
            if _pid_alive(pid):
                return
        except Exception:
            pass
    # fork
    if os.fork() > 0:
        # parent waits briefly for the socket
        for _ in range(40):
            if os.path.exists(SOCK_PATH):
                return
            time.sleep(0.05)
        return
    os.setsid()
    if os.fork() > 0:
        os._exit(0)
    sys.stdin = open(os.devnull, "r")
    sys.stdout = open("/tmp/lyrion-sub-ble.log", "a")
    sys.stderr = sys.stdout
    try:
        os.remove(SOCK_PATH)
    except OSError:
        pass
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(SOCK_PATH)
    os.chmod(SOCK_PATH, 0o600)
    srv.listen(8)
    open(PID_PATH, "w").write(str(os.getpid()))
    get_bridge()

    def _stop(*_a: object) -> None:
        try:
            srv.close()
        except Exception:
            pass
        try:
            os.remove(SOCK_PATH)
        except OSError:
            pass
        try:
            os.remove(PID_PATH)
        except OSError:
            pass
        os._exit(0)

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)
    while True:
        try:
            conn, _ = srv.accept()
        except OSError:
            break
        threading.Thread(target=_serve_conn, args=(conn,), daemon=True).start()

def _serve_conn(conn: socket.socket) -> None:
    try:
        buf = b""
        while True:
            chunk = conn.recv(4096)
            if not chunk:
                break
            buf += chunk
            if b"\n" in buf:
                break
        if not buf:
            return
        try:
            req = json.loads(buf.decode("utf-8"))
        except Exception:
            conn.sendall(b'{"ok":false,"error":"bad_json"}\n')
            return
        resp = handle(req)
        conn.sendall((json.dumps(resp, ensure_ascii=False) + "\n").encode("utf-8"))
    finally:
        try:
            conn.close()
        except Exception:
            pass

def _stop_daemon() -> None:
    if not os.path.exists(PID_PATH):
        return
    try:
        pid = int(open(PID_PATH).read().strip())
    except Exception:
        return
    try:
        cmdline = open("/proc/%d/cmdline" % pid, "rb").read()
    except Exception:
        cmdline = b""
    if b"sub-ble.py" not in cmdline:
        return
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        pass
    for _ in range(20):
        if not _pid_alive(pid):
            break
        time.sleep(0.05)
    for path in (SOCK_PATH, PID_PATH):
        try:
            os.remove(path)
        except OSError:
            pass

def _request_once(req: dict[str, Any]) -> dict[str, Any]:
    start_daemon()
    for _ in range(30):
        if os.path.exists(SOCK_PATH):
            break
        time.sleep(0.05)
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(38)
        sock.connect(SOCK_PATH)
        sock.sendall((json.dumps(req) + "\n").encode("utf-8"))
        buf = b""
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            buf += chunk
            if b"\n" in buf:
                break
        sock.close()
        return json.loads(buf.decode("utf-8") or "{}")
    except Exception as exc:
        return {"ok": False, "error": type(exc).__name__ + ": " + str(exc)}

def client_request(req: dict[str, Any]) -> dict[str, Any]:
    resp = _request_once(req)
    err = str(resp.get("error") or "")
    # An older daemon misses read/write. One born as real-uid root is rejected by D-Bus.
    if resp.get("error") == "unknown_cmd" or "REJECTED" in err or "BleakBluetoothNotAvailable" in err:
        _stop_daemon()
        resp = _request_once(req)
    return resp

def main() -> int:
    _become_real_user()
    p = argparse.ArgumentParser(description="Pi BLE bridge for MartinLogan/Anthem subs")
    p.add_argument("cmd", choices=["hold", "release", "status", "read", "write", "daemon"])
    # REMAINDER keeps a negative level such as -10 from being parsed as a flag.
    p.add_argument("args", nargs=argparse.REMAINDER)
    p.add_argument("--idle", action="store_true", help="release after a short idle instead of now")
    args = p.parse_args()
    rest = [a for a in args.args if a != "--"]
    mac = rest[0] if rest else ""
    setting = rest[1] if len(rest) > 1 else ""
    value = rest[2] if len(rest) > 2 else ""
    if args.cmd == "daemon":
        start_daemon()
        return 0
    if not mac:
        print(json.dumps({"ok": False, "error": "missing_mac"}))
        return 2
    if args.cmd == "read":
        print(json.dumps(client_request({"cmd": "read", "mac": mac})))
        return 0
    if args.cmd == "write":
        print(json.dumps(client_request({
            "cmd": "write", "mac": mac, "setting": setting, "value": value,
        })))
        return 0
    req = {"cmd": args.cmd, "mac": mac}
    if args.cmd == "release" and args.idle:
        req["immediate"] = False
    out = client_request(req)
    print(json.dumps(out, ensure_ascii=False))
    return 0 if out.get("ok") else 1

if __name__ == "__main__":
    sys.exit(main())
