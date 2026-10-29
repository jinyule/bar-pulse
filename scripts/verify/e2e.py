#!/usr/bin/env python3
"""BarPulse end-to-end verification.

1. Cross-checks every metric against an independent macOS tool (top, vm_stat, sysctl, netstat, ioreg).
2. Drives real load (CPU / GPU / network) and checks the readouts react.
3. Launches the real app, opens it through the menu bar's accessibility tree (the same press the
   menu bar performs for a mouse click), switches styles live in its settings window and captures
   real screenshots of the screen.

Screenshots come from Cua Driver's ScreenCaptureKit display recording, so this needs a running
`cua-driver` daemon with Screen Recording + Accessibility, and an unlocked screen (a locked session
hides windows from both). Invoked by scripts/verify.sh.
"""
from __future__ import annotations

import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "build" / "BarPulse.app"
BIN = APP / "Contents" / "MacOS" / "BarPulse"
OUT = ROOT / "verification"
SHOTS = OUT / "screenshots"
TOOLS = Path(os.environ["BP_TOOLS"])
WORK = Path(os.environ["BP_WORK"])
BUNDLE_ID = "dev.barpulse.BarPulse"
# Large files used to generate download traffic; the first one that answers is used.
NET_URLS = [
    "https://mirrors.tuna.tsinghua.edu.cn/ubuntu-releases/24.04/ubuntu-24.04.4-desktop-amd64.iso",
    "https://mirrors.ustc.edu.cn/ubuntu-releases/24.04/ubuntu-24.04.4-desktop-amd64.iso",
    "https://proof.ovh.net/files/1Gb.dat",
    "https://speed.cloudflare.com/__down?bytes=400000000",
]
_net_url: str | None = None

results: list[dict] = []


# ---------------------------------------------------------------- helpers

def run(cmd: list[str], check: bool = False, timeout: float | None = 60) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, check=check, timeout=timeout)


def grab(pattern: str, text: str) -> str:
    """First capture group of `pattern`, with a readable error when a tool's output changes."""
    match = re.search(pattern, text)
    if not match:
        raise RuntimeError(f"pattern {pattern!r} not found in tool output")
    return match.group(1)


def net_url() -> str:
    global _net_url
    if _net_url is None:
        for url in NET_URLS:
            code = run(["curl", "-s", "-o", "/dev/null", "-r", "0-0", "--max-time", "4", "-w", "%{http_code}", url]).stdout
            if code in ("200", "206"):
                _net_url = url
                break
        else:
            _net_url = NET_URLS[0]
    return _net_url


def dump(interval: float = 1.0) -> dict:
    return json.loads(run([str(BIN), "--dump", "--interval", str(interval)], check=True).stdout)


def record(section: str, name: str, ok: bool | None, value: str, reference: str = "") -> None:
    results.append({"section": section, "name": name, "ok": ok, "value": value, "reference": reference})
    mark = {True: "PASS", False: "FAIL", None: "SKIP"}[ok]
    print(f"  [{mark}] {name}: {value}" + (f"  (参考: {reference})" if reference else ""), flush=True)


def gb(value: float) -> str:
    return f"{value / 1024 ** 3:.2f} GB"


def rate(value: float) -> str:
    return f"{value / 1024 ** 2:.2f} MB/s" if value >= 1024 ** 2 else f"{value / 1024:.1f} KB/s"


class Load:
    """Background load generators; always stopped in a finally block."""

    def __init__(self) -> None:
        self.procs: list[subprocess.Popen] = []

    def cpu(self, workers: int) -> "Load":
        self.procs += [subprocess.Popen(["/usr/bin/yes"], stdout=subprocess.DEVNULL) for _ in range(workers)]
        return self

    def gpu(self, seconds: float) -> "Load":
        self.procs.append(subprocess.Popen([str(TOOLS / "gpu-load"), str(seconds)]))
        return self

    def net(self, seconds: float, url: str | None = None) -> "Load":
        self.procs.append(subprocess.Popen(
            ["curl", "-s", "-o", "/dev/null", "--max-time", str(int(seconds)), url or net_url()]))
        return self

    def stop(self) -> None:
        for proc in self.procs:
            if proc.poll() is None:
                proc.terminate()
        for proc in self.procs:
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
        self.procs.clear()


# ---------------------------------------------------------------- 1. metric cross-checks

def top_cpu_usage() -> float:
    out = run(["top", "-l", "2", "-s", "1", "-n", "0"]).stdout
    line = [l for l in out.splitlines() if l.startswith("CPU usage")][-1]
    return 1 - float(grab(r"([\d.]+)% idle", line)) / 100


def vm_stat_used() -> float:
    out = run(["vm_stat"]).stdout
    page = int(grab(r"page size of (\d+)", out))

    def pages(label: str) -> int:
        return int(grab(rf"{label}:\s+(\d+)", out))

    app = pages("Anonymous pages") - pages("Pages purgeable")
    return (app + pages("Pages wired down") + pages("Pages occupied by compressor")) * page


def swap_used() -> float:
    out = run(["sysctl", "-n", "vm.swapusage"]).stdout
    return float(grab(r"used = ([\d.]+)M", out)) * 1024 ** 2


def netstat_received() -> int:
    total = 0
    for line in run(["netstat", "-ibn"]).stdout.splitlines()[1:]:
        cols = line.split()
        if len(cols) >= 10 and cols[0].startswith("en") and cols[2].startswith("<Link#"):
            # Link rows without an address have one column fewer.
            total += int(cols[6] if len(cols) >= 11 else cols[5])
    return total


def ioreg_gpu() -> float | None:
    match = re.search(r'"Device Utilization %"=(\d+)', run(["ioreg", "-r", "-c", "IOAccelerator", "-d", "1"]).stdout)
    return int(match.group(1)) / 100 if match else None


def cross_checks() -> dict:
    section = "指标交叉校验"
    print(f"\n== {section}", flush=True)

    # CPU: both tools side by side for ~6 s, averaged over their 1 s windows. A single window can
    # differ a lot on a bursty machine: the two never sample on the same tick, and each one's
    # start-up work lands in its own first window (which is skipped).
    watcher = subprocess.Popen([str(BIN), "--dump", "--watch", "--interval", "1"], stdout=subprocess.PIPE, text=True)
    top_out = run(["top", "-l", "7", "-s", "1", "-n", "0"]).stdout
    watcher.terminate()
    ours = [json.loads(line)["cpu"]["usage"] for line in watcher.communicate()[0].splitlines()[1:]]
    tops = [1 - float(idle) / 100 for idle in re.findall(r"CPU usage:.*?([\d.]+)% idle", top_out)][1:]
    cpu, reference = sum(ours) / max(len(ours), 1), sum(tops) / max(len(tops), 1)
    record(section, "CPU 总占用 vs top (6 秒均值)", bool(ours and tops) and abs(cpu - reference) <= 0.08,
           f"{cpu:.1%}", f"top {reference:.1%}，{len(ours)} / {len(tops)} 个 1 秒窗口")
    data = dump(1.0)

    snap = data["snapshot"]
    memory = snap["memory"]
    used = memory["app"] + memory["wired"] + memory["compressed"]
    reference_used = vm_stat_used()
    record(section, "内存已使用 vs vm_stat", abs(used - reference_used) / reference_used <= 0.03,
           gb(used), f"vm_stat {gb(reference_used)}")
    record(section, "内存总量 vs hw.memsize", memory["total"] == int(run(["sysctl", "-n", "hw.memsize"]).stdout),
           gb(memory["total"]))
    record(section, "交换区 vs vm.swapusage", abs(memory["swapUsed"] - swap_used()) <= 64 * 1024 ** 2,
           gb(memory["swapUsed"]), f"sysctl {gb(swap_used())}")

    received = netstat_received()
    ours = snap["network"]["totalDownloaded"]
    record(section, "网络累计接收 vs netstat -ibn", abs(ours - received) / max(received, 1) <= 0.01,
           gb(ours), f"netstat {gb(received)}")
    # The address itself stays out of the report: it gets committed with the screenshots.
    record(section, "主网络接口", bool(snap["network"].get("interface")),
           f'{snap["network"].get("interfaceDisplayName")} ({snap["network"].get("interface")})，'
           f'本机 IP {"已获取" if snap["network"].get("localAddress") else "缺失"}')

    gpu = snap["gpu"]
    record(section, "GPU 统计可读 (IOAccelerator)", gpu["available"],
           f'{gpu["usage"]:.0%}，显存占用 {gb(gpu.get("memoryInUse") or 0)}', f"ioreg {ioreg_gpu():.0%}")

    thermal = snap["thermal"]
    readings = {k: thermal.get(k) for k in ("cpu", "gpu", "memory", "soc", "ssd", "battery")}
    plausible = all(v is not None and 15 <= v <= 110 for k, v in readings.items() if k in ("cpu", "gpu", "soc"))
    record(section, "温度传感器读数合理 (15–110°C)", plausible,
           "，".join(f"{k}={v:.1f}°C" for k, v in readings.items() if v is not None))
    fans = thermal.get("fans", [])
    record(section, "风扇转速 (SMC)", len(fans) > 0 or None,
           "，".join(f'风扇{f["id"] + 1} {f["rpm"]:.0f} RPM (范围 {f["minimum"]:.0f}–{f["maximum"]:.0f})' for f in fans) or "无风扇")
    return data


def load_checks(info: dict) -> None:
    section = "负载响应测试"
    print(f"\n== {section}", flush=True)
    cores = info["cpuCores"]

    before = dump(0.5)["snapshot"]["thermal"]["cpu"]
    load = Load().cpu(cores)
    try:
        time.sleep(1.5)
        busy = dump(1.0)["snapshot"]
        time.sleep(8)
        after = dump(0.5)["snapshot"]["thermal"]["cpu"]
    finally:
        load.stop()
    record(section, f"CPU 满载 ({cores} 个 yes 进程)", busy["cpu"]["usage"] >= 0.85, f'{busy["cpu"]["usage"]:.1%}')
    record(section, "满载后 CPU 温度上升", after - before >= 1.5, f"{before:.1f}°C → {after:.1f}°C")

    load = Load().gpu(12)
    try:
        # A freshly built helper can take a few seconds to launch (first-run scan + shader compile).
        started = wait_until(lambda: (ioreg_gpu() or 0) >= 0.5, 10)
        gpu = dump(1.0)["snapshot"]["gpu"]["usage"]
        reference = ioreg_gpu() or 0
    finally:
        load.stop()
    record(section, "GPU 负载 (Metal 计算着色器)", gpu >= 0.5 if started else None, f"{gpu:.0%}", f"ioreg {reference:.0%}")

    # Downloads are bursty, so compare window by window: a long-running `--watch` sampler prints
    # one line per sample and netstat is read the instant each line arrives.
    load = Load()
    for url in NET_URLS[:3]:
        load.net(25, url)
    watcher = subprocess.Popen([str(BIN), "--dump", "--watch", "--interval", "1"], stdout=subprocess.PIPE, text=True)
    pairs: list[tuple[float, float]] = []
    try:
        previous = None
        deadline = time.time() + 16
        while time.time() < deadline and len(pairs) < 12:
            line = watcher.stdout.readline() if watcher.stdout else ""
            now, received = time.monotonic(), netstat_received()
            ours = json.loads(line)["network"]["downloadRate"]
            if previous:
                pairs.append((ours, (received - previous[1]) / (now - previous[0])))
            previous = (now, received)
    finally:
        watcher.terminate()
        load.stop()
    busy = [(ours, ref) for ours, ref in pairs if ref >= 128 * 1024]
    if not busy:
        record(section, "下载速率 vs netstat 同窗口增量", None, "无下载流量", "测速源不可达，跳过")
    else:
        error = sum(abs(ours - ref) for ours, ref in busy) / sum(ref for _, ref in busy)
        record(section, "下载速率 vs netstat 同窗口增量", error <= 0.15,
               f"均值 {rate(sum(o for o, _ in busy) / len(busy))}，峰值 {rate(max(o for o, _ in busy))}",
               f"netstat 均值 {rate(sum(r for _, r in busy) / len(busy))}，{len(busy)} 个 1 秒窗口，偏差 {error:.1%}")


# ---------------------------------------------------------------- 2. UI automation via Cua Driver

def cua(tool: str, args: dict) -> dict:
    out = run(["cua-driver", "call", tool, json.dumps(args)], timeout=60).stdout
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return {"raw": out}


def windows(owner: str | None = None) -> list[dict]:
    return json.loads(run([str(TOOLS / "windows")] + ([owner] if owner else [])).stdout)


def wait_until(predicate, timeout: float = 10, step: float = 0.25):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


def app_pid() -> int | None:
    out = run(["pgrep", "-x", "BarPulse"]).stdout.split()
    return int(out[0]) if out else None


def quit_app() -> None:
    run(["pkill", "-x", "BarPulse"])
    wait_until(lambda: app_pid() is None, 5)


def launch_app(*args: str) -> int:
    quit_app()
    run(["open", str(APP)] + (["--args", *args] if args else []), check=True)
    pid = wait_until(app_pid, 10)
    assert pid, "BarPulse did not start"
    return pid


class MenuBar:
    """The menu bar showing BarPulse, hosted by MenuBarAgent on macOS 26+.

    Every display has its own menu bar, and a crowded one (e.g. a notched laptop screen) folds
    items behind its overflow button, so look for the bar that actually shows the item.
    """

    def __init__(self) -> None:
        bar = wait_until(self._locate, 15)
        assert bar, "BarPulse status item not found in any menu bar"
        self.pid, self.window = bar["pid"], bar["id"]
        self.x, self.y, self.w, self.height = bar["x"], bar["y"], bar["w"], int(bar["h"])

    @staticmethod
    def _index(pid: int, window: int) -> int | None:
        tree = cua("get_window_state", {"pid": pid, "window_id": window, "capture_mode": "ax"}).get("tree_markdown", "")
        match = re.search(r'\[(\d+)\] AXButton "BarPulse"', tree)
        return int(match.group(1)) if match else None

    def _locate(self) -> dict | None:
        # (Menu bar windows don't report themselves as on screen, so don't filter on that.)
        bars = [w for w in windows("MenuBarAgent") if w["layer"] == 24]
        return next((bar for bar in bars if self._index(bar["pid"], bar["id"]) is not None), None)

    def status_item_index(self) -> int | None:
        return self._index(self.pid, self.window)

    def press_status_item(self) -> None:
        index = wait_until(self.status_item_index, 10)
        assert index is not None, "BarPulse status item not found in the menu bar"
        cua("click", {"pid": self.pid, "window_id": self.window, "element_index": index})


def popover_window() -> dict | None:
    found = [w for w in windows("BarPulse") if w["layer"] > 0 and w["w"] > 300 and w["onscreen"]]
    return found[0] if found else None


def open_dashboard(menubar: MenuBar) -> dict:
    if not popover_window():
        menubar.press_status_item()
    window = wait_until(popover_window, 8)
    assert window, "dashboard popover did not open"
    time.sleep(1.2)  # let the open animation finish
    return popover_window() or window


def close_dashboard(menubar: MenuBar) -> None:
    if popover_window():
        menubar.press_status_item()
        wait_until(lambda: popover_window() is None, 5)


class Display:
    """An active display: bounds in global top-left points (like window frames) plus pixel scale."""

    def __init__(self, info: dict) -> None:
        self.x, self.y, self.w, self.h = info["x"], info["y"], info["w"], info["h"]
        self.pixel_size = (info["pixelWidth"], info["pixelHeight"])
        self.scale = info["pixelWidth"] / info["w"]

    def contains(self, x: float, y: float) -> bool:
        return self.x <= x < self.x + self.w and self.y <= y < self.y + self.h

    def pixels(self, x: float, y: float, w: float, h: float) -> tuple[int, int, int, int]:
        """A global point rect as a pixel rect inside a recording of this display (clipped to it)."""
        left, top = max(x, self.x), max(y, self.y)
        right, bottom = min(x + w, self.x + self.w), min(y + h, self.y + self.h)
        assert right > left and bottom > top, f"region {(x, y, w, h)} is not on the recorded display"
        s = self.scale
        return int((left - self.x) * s), int((top - self.y) * s), int((right - left) * s), int((bottom - top) * s)


def record_video(tag: str, seconds: float) -> tuple[Path, Display]:
    """Records a display with Cua Driver and returns the video plus the display it shows.

    Cua Driver picks the display itself, so identify it by the recording's pixel size.
    """
    folder = WORK / f"rec-{tag}"
    shutil.rmtree(folder, ignore_errors=True)
    cua("start_recording", {"output_dir": str(folder), "record_video": True})
    time.sleep(seconds)
    state = cua("stop_recording", {})
    video = Path(state.get("last_video_path") or folder / "recording.mp4")
    wait_until(lambda: video.exists() and video.stat().st_size > 0, 10)
    size = run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
                "-of", "csv=p=0", str(video)]).stdout.strip()
    width, height = (int(v) for v in size.split(","))
    found = [d for d in map(Display, json.loads(run([str(TOOLS / "windows"), "--displays"]).stdout))
             if d.pixel_size == (width, height)]
    assert found, f"recording is {width}×{height}, which matches no active display"
    return video, found[0]


def cursor(move_to: tuple[float, float] | None = None, click: bool = False) -> tuple[float, float]:
    """Current mouse position (global points), optionally moving the mouse there (and clicking) first."""
    args = [str(v) for v in move_to or ()] + (["click"] if move_to and click else [])
    out = run([str(TOOLS / "cursor"), *args]).stdout.split()
    return float(out[0]), float(out[1])


class Frame:
    def __init__(self, path: Path, display: Display) -> None:
        self.path, self.display = path, display


def capture_screen(tag: str, region: tuple[float, float, float, float], seconds: float = 2.2) -> Frame:
    """Records the screen and returns the calmest recent frame as PNG.

    Bars and the live dot animate for ~0.5 s after every sample. Picking the frame that differs
    least from its neighbours inside `region` (global points) avoids freezing a bar mid-transition.
    """
    video, display = record_video(tag, seconds)
    x, y, w, h = display.pixels(*region)
    small_w = 240
    small_h = max(2, int(h * small_w / max(w, 1)) // 2 * 2)
    raw = subprocess.run(["ffmpeg", "-v", "error", "-sseof", "-1.6", "-i", str(video), "-vf",
                          f"crop={w}:{h}:{x}:{y},scale={small_w}:{small_h},format=gray",
                          "-fps_mode", "passthrough", "-f", "rawvideo", "-"],
                         capture_output=True, check=True).stdout
    size = small_w * small_h
    frames = [raw[i:i + size:2] for i in range(0, len(raw) - size + 1, size)]

    def diff(a: bytes, b: bytes) -> int:
        return sum(abs(p - q) for p, q in zip(a, b))

    best, best_score = len(frames) - 1, float("inf")
    for i in range(3, len(frames) - 3):
        score = diff(frames[i - 3], frames[i]) + diff(frames[i], frames[i + 3])
        if score <= best_score:
            best, best_score = i, score
    frame = video.parent / "frame.png"
    run(["ffmpeg", "-v", "error", "-y", "-sseof", "-1.6", "-i", str(video), "-vf", f"select=eq(n\\,{best})",
         "-fps_mode", "passthrough", "-frames:v", "1", "-update", "1", str(frame)], check=True)
    if not frame.exists():
        run(["ffmpeg", "-v", "error", "-y", "-sseof", "-0.2", "-i", str(video), "-frames:v", "1", "-update", "1", str(frame)], check=True)
    return Frame(frame, display)


def crop(frame: Frame, dst: Path, region: tuple[float, float, float, float], ppp: float | None = None) -> Path:
    """Crops a global point rect out of a frame; `ppp` = output pixels per point (default: native)."""
    x, y, w, h = frame.display.pixels(*region)
    filters = f"crop={w}:{h}:{x}:{y}"
    if ppp and ppp != frame.display.scale:
        filters += f",scale=iw*{ppp / frame.display.scale}:ih*{ppp / frame.display.scale}:flags=lanczos"
    run(["ffmpeg", "-v", "error", "-y", "-i", str(frame.path), "-vf", filters, str(dst)], check=True)
    return dst


def item_center(menubar: MenuBar) -> float:
    """The popover's arrow points at the status item, so its centre is the item's centre."""
    window = open_dashboard(menubar)
    close_dashboard(menubar)
    return window["x"] + window["w"] / 2


def menubar_shots(menubar: MenuBar, center: float, name: str, frame: Frame | None = None, zoom: float = 300) -> None:
    item = (center - zoom / 2, menubar.y, zoom, menubar.height)
    frame = frame or capture_screen(name, item)
    left = max(menubar.x, center - 420)
    crop(frame, SHOTS / f"{name}.png", (left, menubar.y, menubar.x + menubar.w - left, menubar.height), 2)
    crop(frame, SHOTS / f"{name}-zoom.png", item, 4)


def dashboard_shot(menubar: MenuBar, name: str) -> tuple[dict, Frame]:
    window = open_dashboard(menubar)
    frame = capture_screen(name, (window["x"], window["y"], window["w"], window["h"]))
    margin = 36
    top = frame.display.y  # include the menu bar the popover hangs from
    crop(frame, SHOTS / f"{name}.png",
         (window["x"] - margin, top, window["w"] + 2 * margin, window["y"] + window["h"] + margin - top))
    return window, frame


def app_overhead(pid: int) -> tuple[float, float]:
    """Average CPU % and memory footprint (MB) of the running app over ~12 s, as `top` reports them."""
    out = run(["top", "-l", "7", "-s", "2", "-pid", str(pid), "-stats", "pid,cpu,mem"], timeout=60).stdout
    rows = [line.split() for line in out.splitlines() if line.split()[:1] == [str(pid)]][1:]
    cpu = sum(float(row[1]) for row in rows) / max(len(rows), 1)
    memory = rows[-1][2].rstrip("+-") if rows else "0M"
    factor = {"K": 1 / 1024, "M": 1, "G": 1024}.get(memory[-1], 1)
    return cpu, float(memory[:-1]) * factor


def screen_locked() -> bool:
    out = run(["ioreg", "-n", "Root", "-d1", "-a"]).stdout
    users = plistlib.loads(out.encode()).get("IOConsoleUsers", []) if out else []
    return any(user.get("CGSSessionScreenIsLocked") for user in users)


def screen_overlay() -> str | None:
    """Owner of a full-screen window stacked above everything (e.g. another agent's "in use" guard)."""
    displays = json.loads(run([str(TOOLS / "windows"), "--displays"]).stdout)
    for w in windows():
        if w["onscreen"] and w["layer"] >= 1000 and any(
                w["x"] <= d["x"] and w["y"] <= d["y"] and w["w"] >= d["w"] and w["h"] >= d["h"] for d in displays):
            return w["owner"]
    return None


def ax_press(pid: int, window_id: int, pattern: str) -> bool:
    """AX-presses the first element of a window whose tree line matches `pattern` (group 1 = index)."""
    tree = cua("get_window_state", {"pid": pid, "window_id": window_id, "capture_mode": "ax"}).get("tree_markdown", "")
    match = re.search(pattern, tree)
    if match:
        cua("click", {"pid": pid, "window_id": window_id, "element_index": int(match.group(1))})
    return bool(match)


def open_settings(pid: int, dashboard: dict, park: tuple[float, float]) -> dict | None:
    """Presses the dashboard's 设置 button; returns the settings window once it's on screen."""
    tree = dashboard_texts(pid, dashboard)
    button = re.search(r'\[(\d+)\] AXButton[^\n]*设置', tree)
    if button:
        cua("click", {"pid": pid, "window_id": dashboard["id"], "element_index": int(button.group(1))})
    settings = wait_until(lambda: next((w for w in windows("BarPulse") if w["layer"] == 0 and w["h"] > 200 and w["onscreen"]), None), 8)
    if settings:
        # An accessibility press isn't user input, so macOS declines to activate the app and the
        # window would render inactive (grey controls). Click its title bar like a user would.
        cursor((settings["x"] + settings["w"] / 2, settings["y"] + 14), click=True)
        cursor(park)
        time.sleep(1.5)
    return settings


def read_default(key: str) -> str:
    return run(["defaults", "read", BUNDLE_ID, key]).stdout.strip()


def dashboard_texts(pid: int, window: dict) -> str:
    return cua("get_window_state", {"pid": pid, "window_id": window["id"], "capture_mode": "ax"}).get("tree_markdown", "")


def ui_checks(info: dict) -> None:
    section = "界面端到端"
    print(f"\n== {section}", flush=True)
    if screen_locked():
        # Locked sessions hide windows from accessibility and from screen capture.
        record(section, "屏幕处于解锁状态", False, "已锁定", "界面验证需要在解锁的桌面上运行")
        return
    overlay = screen_overlay()
    if overlay:
        record(section, "屏幕未被其他程序遮挡", False, f"{overlay} 的全屏窗口覆盖了屏幕", "等它结束后再运行界面验证")
        return
    SHOTS.mkdir(parents=True, exist_ok=True)
    run(["defaults", "delete", BUNDLE_ID])

    # Status items live in the menu bar of the display under the mouse; a crowded one (e.g. a
    # notched laptop screen) folds BarPulse into its overflow. Work on the display being recorded.
    # The pointer is parked at the display's left edge, clear of the item, popover and windows.
    _, display = record_video("probe", 1)
    home = cursor()
    park = (display.x + 24, display.y + display.h / 2)
    cursor(park)
    try:
        ui_flow(info, section, park)
    finally:
        cursor(home)


def ui_flow(info: dict, section: str, park: tuple[float, float]) -> None:

    pid = launch_app()
    menubar = MenuBar()
    record(section, "状态栏项出现在菜单栏 (MenuBarAgent AX)", wait_until(menubar.status_item_index, 10) is not None,
           f"pid {pid}")
    time.sleep(2)
    center = item_center(menubar)
    record(section, "点击状态栏项打开仪表盘", True, f"面板中心 x={center:.0f}")
    menubar_shots(menubar, center, "01-menubar")

    # Idle period doubles as the app's own overhead measurement (dashboard closed).
    cpu, memory = app_overhead(pid)
    record(section, "BarPulse 自身开销 (面板关闭，top 12 秒均值)", cpu < 3 and memory < 100,
           f"CPU {cpu:.2f}%，内存 {memory:.0f} MB", "阈值 CPU < 3%，内存 < 100 MB")

    # Build up chart history: idle → combined load → idle, so charts show a real event.
    time.sleep(3)
    load = Load().cpu(info["cpuCores"] // 2).gpu(24).net(24)
    try:
        time.sleep(10)
        window, frame = dashboard_shot(menubar, "03-dashboard-under-load")
        menubar_shots(menubar, center, "03-menubar-under-load", frame)
        tree = dashboard_texts(pid, window)
        cpu_text = re.search(r'AXStaticText = "CPU"\n.*\n\s*- AXStaticText = "(\d+)%"', tree)
        busy = dump(1.0)["snapshot"]
        record(section, "负载期间仪表盘 CPU 读数 (界面文本)", bool(cpu_text) and int(cpu_text.group(1)) >= 30,
               f'{cpu_text.group(1) if cpu_text else "?"}%', f'dump {busy["cpu"]["usage"]:.0%}')

        # Short clip proving the readouts animate in real time.
        video, display = record_video("clip", 6)
        top = display.y
        x, y, w, h = display.pixels(window["x"] - 36, top, window["w"] + 72, window["y"] + window["h"] + 36 - top)
        run(["ffmpeg", "-v", "error", "-y", "-i", str(video), "-vf",
             f"crop={w}:{h}:{x}:{y},fps=15,scale=iw/{display.scale}:-2",
             "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "26", str(SHOTS / "live-dashboard.mp4")], check=True)
        x, y, w, h = display.pixels(center - 150, menubar.y, 300, menubar.height)
        run(["ffmpeg", "-v", "error", "-y", "-i", str(video), "-vf",
             f"crop={w}:{h}:{x}:{y},fps=8,scale=iw*2/{display.scale}:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse",
             str(SHOTS / "live-menubar.gif")], check=True)
        close_dashboard(menubar)
    finally:
        load.stop()

    time.sleep(25)
    window, _ = dashboard_shot(menubar, "02-dashboard")
    tree = dashboard_texts(pid, window)
    data = dump(1.0)["snapshot"]
    used_text = re.search(r'AXStaticText = "([\d.]+) GB"\n\s*- AXStaticText = "已使用"', tree)
    used = (data["memory"]["app"] + data["memory"]["wired"] + data["memory"]["compressed"]) / 1024 ** 3
    record(section, "仪表盘内存读数与采样一致 (界面文本)",
           bool(used_text) and abs(float(used_text.group(1)) - used) <= 0.6,
           f'{used_text.group(1) if used_text else "?"} GB', f"dump {used:.1f} GB")
    interface = f'{data["network"].get("interfaceDisplayName")} · {data["network"].get("interface")}'
    record(section, "仪表盘网络接口 (界面文本)", interface in tree, interface)
    record(section, "仪表盘包含 5 类指标卡片", all(t in tree for t in ('"CPU"', '"GPU"', '"内存"', '"网络"', '"温度与风扇"')),
           "CPU / GPU / 内存 / 网络 / 温度与风扇")

    # Cost while the dashboard is on screen (it is built on open and released on close).
    cpu, memory = app_overhead(pid)
    record(section, "BarPulse 自身开销 (面板打开，top 12 秒均值)", cpu < 12 and memory < 250,
           f"CPU {cpu:.2f}%，内存 {memory:.0f} MB", "阈值 CPU < 12%，内存 < 250 MB")

    # Settings, opened from the dashboard's own button.
    settings = open_settings(pid, popover_window() or window, park)
    record(section, "点击「设置」打开设置窗口", bool(settings), f'{int(settings["w"])}×{int(settings["h"])}' if settings else "未打开")
    if not settings:
        return
    frame = capture_screen("04-settings", (settings["x"], settings["y"], settings["w"], settings["h"]))
    m = 30
    crop(frame, SHOTS / "04-settings.png", (settings["x"] - m, settings["y"] - m, settings["w"] + 2 * m, settings["h"] + 2 * m))

    # Everything below is switched live in the settings window, so it also checks that settings
    # apply immediately (no relaunch). Form labels are separate texts in front of their controls;
    # the title bar buttons come in the order close, zoom, minimise.
    colorful = r'AXStaticText = "彩色指示条"\n\s*- \[(\d+)\] AXCheckBox'
    appearance = r'AXStaticText = "仪表盘外观"\n\s*- \[(\d+)\] AXPopUpButton'
    close_button = r'\[(\d+)\] AXButton \[actions=\[press\]\]\n\s*- \[\d+\] AXButton \[actions=\[press,showmenu\]\]'

    def press(pattern: str) -> bool:
        pressed = ax_press(pid, settings["id"], pattern)
        time.sleep(1.5)
        return pressed

    def close_settings() -> bool:
        press(close_button)
        return bool(wait_until(lambda: not any(w["layer"] == 0 and w["onscreen"] for w in windows("BarPulse")), 5))

    pressed = press(r'\[(\d+)\] AXRadioButton \(单行图标\)')
    inline_center = item_center(menubar)
    menubar_shots(menubar, inline_center, "06-menubar-inline", zoom=420)
    record(section, "设置切换「单行图标」样式，菜单栏即时生效", pressed and abs(inline_center - center) > 5,
           f"状态栏项中心 {center:.0f} → {inline_center:.0f}", "screenshots/06-menubar-inline-zoom.png")

    pressed = press(r'\[(\d+)\] AXRadioButton \(双行紧凑\)') and press(colorful)
    mono_center = item_center(menubar)
    menubar_shots(menubar, mono_center, "07-menubar-monochrome")
    record(section, "设置关闭「彩色指示条」，菜单栏即时生效", pressed and read_default("colorful") == "0",
           f"colorful = {read_default('colorful')}", "screenshots/07-menubar-monochrome-zoom.png")
    press(colorful)

    # Dark appearance (app-scoped; the system setting is left untouched), shot with the settings
    # window closed so nothing peeks out behind the dashboard.
    pressed = press(appearance) and press(r'\[(\d+)\] AXMenuItem "深色"')
    closed = close_settings()
    record(section, "关闭设置窗口", closed, "已关闭" if closed else "仍在屏幕上")
    load = Load().cpu(info["cpuCores"] // 3).gpu(6)
    try:
        time.sleep(6)
    finally:
        load.stop()
    time.sleep(6)
    window, _ = dashboard_shot(menubar, "05-dashboard-dark")
    record(section, "设置切换深色仪表盘", pressed and read_default("appearance") == "dark",
           f"appearance = {read_default('appearance')}", "screenshots/05-dashboard-dark.png")

    # Back to the defaults, through the same UI.
    settings = open_settings(pid, window, park)
    if settings:
        if press(appearance):
            press(r'\[(\d+)\] AXMenuItem "跟随系统"')
        close_settings()
    run(["defaults", "delete", BUNDLE_ID])


# ---------------------------------------------------------------- report

def write_report(info: dict) -> None:
    lines = [
        "# BarPulse 端到端验证报告",
        "",
        f"- 时间：{time.strftime('%Y-%m-%d %H:%M:%S')}",
        f"- 机器：{info['chip']} · {info['cpuCores']} 核 CPU · {info.get('gpuCores')} 核 GPU · {info['memory'] / 1024 ** 3:.0f} GB · {info['osVersion']}",
        "- 截图来源：Cua Driver 的 ScreenCaptureKit 整屏录制（真实屏幕像素，非离屏渲染）",
        "- 交互方式：通过菜单栏 (MenuBarAgent) 的辅助功能树按下 BarPulse 状态栏项，与鼠标点击走同一路径",
        "",
    ]
    for section in dict.fromkeys(r["section"] for r in results):
        lines += [f"## {section}", "", "| 结果 | 检查项 | BarPulse | 参考值 |", "|---|---|---|---|"]
        for r in (r for r in results if r["section"] == section):
            mark = {True: "✅", False: "❌", None: "⏭️"}[r["ok"]]
            lines.append(f"| {mark} | {r['name']} | {r['value']} | {r['reference']} |")
        lines.append("")
    shots = [
        ("01-menubar-zoom", "菜单栏状态项放大"),
        ("02-dashboard", "仪表盘（图表含一次负载事件）"),
        ("03-dashboard-under-load", "CPU + GPU + 网络同时加压时的仪表盘"),
        ("03-menubar-under-load-zoom", "加压时的菜单栏"),
        ("04-settings", "设置窗口（含菜单栏实时预览）"),
        ("05-dashboard-dark", "深色外观"),
        ("06-menubar-inline-zoom", "单行图标样式"),
        ("07-menubar-monochrome-zoom", "单色样式"),
    ]
    lines += ["## 截图", ""]
    for name, title in shots:
        if (SHOTS / f"{name}.png").exists():
            lines += [f"### {title}", "", f"![{title}](screenshots/{name}.png)", ""]
    lines += ["实时刷新动图：[live-menubar.gif](screenshots/live-menubar.gif) · 视频：[live-dashboard.mp4](screenshots/live-dashboard.mp4)", ""]
    (OUT / "README.md").write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    data = cross_checks()
    info = data["info"]
    load_checks(info)
    if "--no-ui" not in sys.argv:
        ui_checks(info)
    write_report(info)
    failed = [r for r in results if r["ok"] is False]
    print(f"\n{len(results) - len(failed)}/{len(results)} 项通过，报告：{OUT / 'README.md'}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
