#!/usr/bin/env python3
"""BarPulse end-to-end verification.

1. Cross-checks every metric against an independent macOS tool (top, vm_stat, sysctl, netstat, ioreg).
2. Drives real load (CPU / GPU / network) and checks the readouts react.
3. Launches the real app, opens it through the menu bar's accessibility tree (the same press the
   menu bar performs for a mouse click), switches styles live in its settings window and captures
   real screenshots of the screen.
4. Clicks the dashboard's transparency slider and drags its edges with mouse events posted to the
   app, and checks the saved values, the window frames and (against a known backdrop) how much
   shows through.

All UI work happens on the display Cua Driver records, never the main one, without taking
keyboard focus, so the user can keep working on the main display meanwhile.

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
    """The menu bar of the recorded display, drawn by MenuBarAgent on macOS 26+.

    Every display has its own menu bar, but status items only show in the active one, which
    follows the user's clicks. The checks run on the recorded display while the user may keep
    working on another one, so before the item is needed it is brought over with a click on an
    empty stretch of this bar (the pointer goes straight back; the frontmost app doesn't change).
    """

    def __init__(self, display: "Display") -> None:
        bar = wait_until(lambda: next((w for w in windows("MenuBarAgent") if w["layer"] == 24
                                       and abs(w["x"] - display.x) < 1 and abs(w["y"] - display.y) < 1), None), 10)
        assert bar, "no menu bar on the recorded display"
        self.display = display
        self.pid, self.window = bar["pid"], bar["id"]
        self.x, self.y, self.w, self.height = bar["x"], bar["y"], bar["w"], int(bar["h"])
        self.last_item: dict | None = None

    def item_frame(self) -> dict | None:
        """The status item's frame, if it is showing in this menu bar."""
        found = next((f for f in ax_frames(self.pid, "BarPulse") if f["role"] == "AXButton"
                      and self.x <= f["x"] < self.x + self.w and self.y <= f["y"] < self.y + self.height), None)
        self.last_item = found or self.last_item
        return found

    def summon(self) -> None:
        if self.item_frame():
            return
        home = cursor()
        cursor((self.x + self.w * 0.45, self.y + self.height / 2), click=True)
        cursor(home)
        assert wait_until(self.item_frame, 5), "BarPulse status item did not move to the recorded display"

    def status_item_index(self) -> int | None:
        tree = cua("get_window_state", {"pid": self.pid, "window_id": self.window, "capture_mode": "ax"}).get("tree_markdown", "")
        match = re.search(r'\[(\d+)\] AXButton "BarPulse"', tree)
        return int(match.group(1)) if match else None

    def press_status_item(self) -> None:
        self.summon()
        index = wait_until(self.status_item_index, 10)
        assert index is not None, "BarPulse status item not found in the menu bar"
        cua("click", {"pid": self.pid, "window_id": self.window, "element_index": index})


def dashboard_window() -> dict | None:
    found = [w for w in windows("BarPulse") if w["layer"] > 0 and w["w"] > 300 and w["onscreen"]]
    return found[0] if found else None


def press_item_anywhere() -> None:
    """AX-presses the status item in whichever menu bar shows it (used to close a stray panel)."""
    for bar in (w for w in windows("MenuBarAgent") if w["layer"] == 24):
        tree = cua("get_window_state", {"pid": bar["pid"], "window_id": bar["id"], "capture_mode": "ax"}).get("tree_markdown", "")
        match = re.search(r'\[(\d+)\] AXButton "BarPulse"', tree)
        if match:
            cua("click", {"pid": bar["pid"], "window_id": bar["id"], "element_index": int(match.group(1))})
            return


def open_dashboard(menubar: MenuBar) -> dict:
    """Opens the dashboard on the recorded display, retrying if a click elsewhere interferes."""
    for _ in range(4):
        if not dashboard_window():
            menubar.press_status_item()
        window = wait_until(dashboard_window, 8)
        if window and not menubar.display.contains(window["x"] + 1, window["y"] + 1):
            # The active menu bar moved to another display between summoning and pressing.
            press_item_anywhere()
            wait_until(lambda: dashboard_window() is None, 5)
            continue
        time.sleep(1.2)  # let the open animation finish
        if dashboard_window():
            return dashboard_window()
    raise AssertionError("dashboard did not stay open on the recorded display")


def close_dashboard(menubar: MenuBar) -> None:
    if dashboard_window():
        press_item_anywhere()
        wait_until(lambda: dashboard_window() is None, 5)


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
    """Records a display with Cua Driver for `seconds` and returns the video plus the display it shows."""
    return record_during(tag, lambda: time.sleep(seconds))


def record_during(tag: str, action, pad: float = 0) -> tuple[Path, Display]:
    """Records a display with Cua Driver while `action` runs (plus `pad` seconds on either side).

    Cua Driver picks the display itself, so identify it by the recording's pixel size.
    """
    folder = WORK / f"rec-{tag}"
    shutil.rmtree(folder, ignore_errors=True)
    cua("start_recording", {"output_dir": str(folder), "record_video": True})
    time.sleep(pad)
    action()
    time.sleep(pad)
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


class Backdrop:
    """A fixed picture behind the dashboard while it's being photographed.

    Screenshots then show the same wallpaper through the glass instead of whatever windows happen
    to be open (which would otherwise end up in the committed images), and transparency can be
    measured against a known background. It floats above normal windows and below the menu bar.
    """

    IMAGE = Path("/System/Library/Desktop Pictures/Sonoma.heic")

    def __init__(self, display: Display, menubar: "MenuBar") -> None:
        top = menubar.y + menubar.height
        self.rect = (display.x, top, display.w, display.y + display.h - top)
        self.proc: subprocess.Popen | None = None

    def __enter__(self) -> "Backdrop":
        if self.IMAGE.exists():
            self.proc = subprocess.Popen([str(TOOLS / "backdrop"), *map(str, self.rect), str(self.IMAGE)])
            wait_until(lambda: any(w["onscreen"] for w in windows("backdrop")), 5)
            time.sleep(0.5)
        return self

    def __exit__(self, *_) -> None:
        if self.proc:
            self.proc.terminate()
            self.proc.wait(timeout=5)
            self.proc = None


def region_rgb(frame: Frame, region: tuple[float, float, float, float], width: int = 160) -> bytes:
    """A region of a captured frame (global points), downscaled to `width` pixels, as raw RGB."""
    x, y, w, h = frame.display.pixels(*region)
    height = max(2, int(h * width / max(w, 1)) // 2 * 2)
    return subprocess.run(["ffmpeg", "-v", "error", "-i", str(frame.path), "-vf",
                           f"crop={w}:{h}:{x}:{y},scale={width}:{height}", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                          capture_output=True, check=True).stdout


def mean_difference(a: bytes, b: bytes) -> float:
    """Mean absolute difference per colour channel (0–255) between two equally sized images."""
    return sum(abs(p - q) for p, q in zip(a, b)) / max(1, min(len(a), len(b)))


def hide_other_items(menubar: MenuBar, display: Display, region: tuple[float, float, float, float]) -> str:
    """ffmpeg filters, run right after cropping `region`, that blur the menu bar in it except BarPulse.

    The other status items say what else the user runs, which has no place in published images
    (the full-width menu bar captures are git-ignored for the same reason).
    """
    x, y, w, h = display.pixels(*region)
    s = display.scale
    rows = min(h, int((menubar.y + menubar.height - display.y) * s) - y)
    if rows <= 0:
        return ""
    blur = f"[bar]crop={w}:{rows}:0:0,gblur=sigma={8 * s:g}[blurred];[base][blurred]overlay=0:0"
    item = menubar.item_frame() or menubar.last_item
    left = max(0, int((item["x"] - 6 - display.x) * s) - x) if item else w
    right = min(w, int((item["x"] + item["w"] + 6 - display.x) * s) - x) if item else 0
    if right - left < 2:
        return f",split[base][bar];{blur}"
    return f",split=3[base][bar][item];{blur}[out];[item]crop={right - left}:{rows}:{left}:0[sharp];[out][sharp]overlay={left}:0"


def gif(video: Path, display: Display, region: tuple[float, float, float, float], dst: Path, width: int = 420,
        menubar: MenuBar | None = None) -> None:
    x, y, w, h = display.pixels(*region)
    hide = hide_other_items(menubar, display, region) if menubar else ""
    run(["ffmpeg", "-v", "error", "-y", "-i", str(video), "-vf",
         f"crop={w}:{h}:{x}:{y}{hide},fps=12,scale={width}:-1:flags=lanczos,split[a][b];"
         "[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle",
         str(dst)], check=True)


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


def crop(frame: Frame, dst: Path, region: tuple[float, float, float, float], ppp: float | None = None,
         menubar: MenuBar | None = None) -> Path:
    """Crops a global point rect out of a frame; `ppp` = output pixels per point (default: native).

    With `menubar`, the rest of the menu bar is blurred around the status item (see hide_other_items).
    """
    x, y, w, h = frame.display.pixels(*region)
    filters = f"crop={w}:{h}:{x}:{y}"
    if menubar:
        filters += hide_other_items(menubar, frame.display, region)
    if ppp and ppp != frame.display.scale:
        filters += f",scale=iw*{ppp / frame.display.scale}:ih*{ppp / frame.display.scale}:flags=lanczos"
    run(["ffmpeg", "-v", "error", "-y", "-i", str(frame.path), "-vf", filters, str(dst)], check=True)
    return dst


def ax_frames(pid: int, title: str) -> list[dict]:
    """Screen frames (global top-left points) of a process's accessibility elements with this title."""
    return json.loads(run([str(TOOLS / "axframe"), str(pid), title]).stdout or "[]")


def item_center(menubar: MenuBar) -> float:
    """Centre of the BarPulse status item, from the menu bar's accessibility tree."""
    menubar.summon()
    time.sleep(1)  # a style change resizes the item; let the menu bar lay it out again
    item = menubar.item_frame()
    assert item, "BarPulse status item has no frame in the menu bar"
    return item["x"] + item["w"] / 2


def menubar_shots(menubar: MenuBar, center: float, name: str, frame: Frame | None = None, zoom: float = 300) -> None:
    item = (center - zoom / 2, menubar.y, zoom, menubar.height)
    if not frame:
        menubar.summon()
        frame = capture_screen(name, item)
    left = max(menubar.x, center - 420)
    crop(frame, SHOTS / f"{name}.png", (left, menubar.y, menubar.x + menubar.w - left, menubar.height), 2)
    crop(frame, SHOTS / f"{name}-zoom.png", item, 4)


def steady(menubar: MenuBar, step):
    """Runs `step(dashboard window)`, again if a click elsewhere closed the dashboard meanwhile.

    The panel closes on any click outside it, like a menu, and the user may be clicking away on
    another display while the checks run.
    """
    for _ in range(3):
        result = step(open_dashboard(menubar))
        if dashboard_window():
            return result
    raise AssertionError("dashboard kept closing during a step (clicks elsewhere?)")


def dashboard_shot(menubar: MenuBar, name: str) -> tuple[dict, Frame]:
    window, frame = steady(menubar, lambda window: (window, capture_screen(name, (window["x"], window["y"], window["w"], window["h"]))))
    margin = 36
    top = frame.display.y  # include the menu bar the panel hangs from
    crop(frame, SHOTS / f"{name}.png",
         (window["x"] - margin, top, window["w"] + 2 * margin, window["y"] + window["h"] + margin - top), menubar=menubar)
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


def open_settings(pid: int, dashboard: dict) -> dict | None:
    """Presses the dashboard's 设置 button; returns the settings window once it's on screen.

    An accessibility press isn't user input, so macOS declines to activate the app: the window
    renders inactive (grey controls) and keyboard focus stays wherever the user has it.
    """
    tree = dashboard_texts(pid, dashboard)
    button = re.search(r'\[(\d+)\] AXButton[^\n]*设置', tree)
    if button:
        cua("click", {"pid": pid, "window_id": dashboard["id"], "element_index": int(button.group(1))})
    settings = wait_until(lambda: next((w for w in windows("BarPulse") if w["layer"] == 0 and w["h"] > 200 and w["onscreen"]), None), 8)
    if settings:
        time.sleep(1.5)
    return settings


def front_app() -> str:
    """Name of the frontmost app (the one with keyboard focus)."""
    out = run(["lsappinfo", "info", "-only", "name", run(["lsappinfo", "front"]).stdout.strip()]).stdout
    match = re.search(r'"?(?:LSDisplayName|name)"?\s*=\s*"([^"]*)"', out) or re.search(r'"([^"]+)"', out)
    return match.group(1) if match else out.strip()


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

    # Everything happens on the display Cua Driver records, never on the main display, so the user
    # can keep working there: the dashboard, settings window and backdrop all open on the recorded
    # display, the panel is driven with accessibility presses and events posted straight to the
    # app, and nothing takes keyboard focus. The pointer only moves for the brief menu bar clicks
    # that bring the status item over (see MenuBar.summon).
    _, display = record_video("probe", 1)
    screens = json.loads(run([str(TOOLS / "windows"), "--displays"]).stdout)
    main = next(d for d in screens if d["main"])
    if len(screens) > 1 and (display.x, display.y) == (main["x"], main["y"]):
        record(section, "在副显示器上验证", False, "Cua Driver 录制的是主显示器", "界面验证只在副显示器上进行，以免打扰主显示器上的工作")
        return
    ui_flow(info, section, display)


def ui_flow(info: dict, section: str, display: Display) -> None:
    # The screenshots get published: the app blanks out the local IP address.
    pid = launch_app("--redact-private")
    menubar = MenuBar(display)
    menubar.summon()
    record(section, "状态栏项出现在菜单栏 (MenuBarAgent AX)", wait_until(menubar.status_item_index, 10) is not None,
           f"pid {pid}")
    time.sleep(2)
    center = item_center(menubar)
    front = front_app()
    window = open_dashboard(menubar)
    after = front_app()
    record(section, "打开仪表盘不抢前台应用和键盘焦点", after == front, f"打开前后前台应用：{front} → {after}")
    close_dashboard(menubar)
    # Centred under the item, unless that would push it past the screen edge (8 pt margin).
    middle = window["x"] + window["w"] / 2
    edge = window["x"] <= display.x + 8.5 or window["x"] + window["w"] >= display.x + display.w - 8.5
    gap = window["y"] - (menubar.y + menubar.height)
    record(section, "点击状态栏项打开仪表盘，面板挂在状态栏项正下方", (abs(middle - center) <= 2 or edge) and 0 <= gap <= 12,
           f'面板 {window["w"]}×{window["h"]}，中心 x={middle:.0f}，距菜单栏 {gap:.0f} pt', f"状态栏项中心 x={center:.0f}")
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
        with Backdrop(display, menubar):
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
        region = (window["x"] - 36, top, window["w"] + 72, window["y"] + window["h"] + 36 - top)
        x, y, w, h = display.pixels(*region)
        run(["ffmpeg", "-v", "error", "-y", "-i", str(video), "-vf",
             f"crop={w}:{h}:{x}:{y}{hide_other_items(menubar, display, region)},fps=15,scale=iw/{display.scale}:-2",
             "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "26", str(SHOTS / "live-dashboard.mp4")], check=True)
        x, y, w, h = display.pixels(center - 150, menubar.y, 300, menubar.height)
        run(["ffmpeg", "-v", "error", "-y", "-i", str(video), "-vf",
             f"crop={w}:{h}:{x}:{y},fps=8,scale=iw*2/{display.scale}:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse",
             str(SHOTS / "live-menubar.gif")], check=True)
        close_dashboard(menubar)
    finally:
        load.stop()

    time.sleep(25)
    with Backdrop(display, menubar):
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
    settings = open_settings(pid, open_dashboard(menubar))
    record(section, "点击「设置」打开设置窗口，出现在状态栏项所在的显示器", bool(settings) and display.contains(settings["x"] + 1, settings["y"] + 1),
           f'{int(settings["w"])}×{int(settings["h"])}，位于 ({settings["x"]:.0f}, {settings["y"]:.0f})' if settings else "未打开")
    if not settings:
        return
    # Just the window (ScreenCaptureKit window capture, transparent corners): a normal window can
    # always end up behind other windows, which then must not show up in the screenshot.
    cua("get_window_state", {"pid": pid, "window_id": settings["id"], "capture_mode": "vision",
                             "screenshot_out_file": str(SHOTS / "04-settings.png")})

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
    with Backdrop(display, menubar):
        window, _ = dashboard_shot(menubar, "05-dashboard-dark")
    record(section, "设置切换深色仪表盘", pressed and read_default("appearance") == "dark",
           f"appearance = {read_default('appearance')}", "screenshots/05-dashboard-dark.png")

    # Back to the defaults, through the same UI.
    settings = open_settings(pid, open_dashboard(menubar))
    if settings:
        if press(appearance):
            press(r'\[(\d+)\] AXMenuItem "跟随系统"')
        close_settings()

    panel_checks(pid, menubar, display)
    run(["defaults", "delete", BUNDLE_ID])
    launch_app()  # leave it running as usual, showing the IP again


TRANSPARENCY_MAX = 0.9  # AppSettings.transparencyRange
MIN_WIDTH = 640         # DashboardView's minWidth


def drag(pid: int, window: dict, display: Display, start: tuple[float, float], end: tuple[float, float], ms: int = 500) -> None:
    """Drags inside a window (global points) with mouse events posted straight to the app.

    They go through AppKit's normal event handling, but the user's pointer stays where it is.
    """
    def local(point: tuple[float, float]) -> tuple[float, float]:
        return (point[0] - window["x"]) * display.scale, (point[1] - window["y"]) * display.scale

    (fx, fy), (tx, ty) = local(start), local(end)
    cua("drag", {"pid": pid, "window_id": window["id"], "from_x": fx, "from_y": fy, "to_x": tx, "to_y": ty,
                 "duration_ms": ms, "steps": min(200, max(20, ms // 16))})
    time.sleep(0.4)


def click_at(pid: int, window: dict, display: Display, point: tuple[float, float]) -> None:
    """Clicks inside a window (global points) with mouse events posted straight to the app."""
    cua("click", {"pid": pid, "window_id": window["id"],
                  "x": (point[0] - window["x"]) * display.scale, "y": (point[1] - window["y"]) * display.scale})


def transparency_slider(pid: int, window: dict) -> dict:
    """Frame of the dashboard footer's transparency slider."""
    return next(f for f in ax_frames(pid, "透明度") if f["role"] == "AXSlider"
                and window["x"] <= f["x"] < window["x"] + window["w"] and window["y"] <= f["y"] < window["y"] + window["h"])


def set_transparency(pid: int, window: dict, display: Display, value: float, slider: dict | None = None) -> float:
    """Clicks the dashboard footer's transparency slider where `value` lies; returns the saved value.

    The knob jumps to a click on its track. (Dragging the knob works too, but SwiftUI's slider
    follows the real pointer while dragging, and these checks leave the pointer alone.)
    """
    slider = slider or transparency_slider(pid, window)
    knob = 7.5  # the knob's centre travels between half-knob insets at either end of the track
    fraction = min(1.0, max(0.0, value / TRANSPARENCY_MAX))
    x = slider["x"] + 1 if fraction == 0 else slider["x"] + slider["w"] - 1 if fraction == 1 else \
        slider["x"] + knob + (slider["w"] - 2 * knob) * fraction
    click_at(pid, window, display, (x, slider["y"] + slider["h"] / 2))
    time.sleep(0.3)
    return float(read_default("dashboardTransparency") or 0)


def drag_edge(pid: int, window: dict, display: Display, edge: str, dx: float, dy: float, ms: int = 500) -> dict:
    """Drags a dashboard edge ("left", "right", "bottom", or "corner" for bottom-right) by (dx, dy)."""
    x, y, w, h = window["x"], window["y"], window["w"], window["h"]
    start = {"left": (x + 3, y + h / 2), "right": (x + w - 3, y + h / 2),
             "bottom": (x + w / 2, y + h - 3), "corner": (x + w - 8, y + h - 8)}[edge]
    drag(pid, window, display, start, (start[0] + dx, start[1] + dy), ms)
    return dashboard_window() or window


def panel_checks(pid: int, menubar: MenuBar, display: Display) -> None:
    """Transparency and resizing, dragged the way a user would."""
    section = "面板透明度与大小"
    print(f"\n== {section}", flush=True)
    margin = 36

    def size(window: dict) -> str:
        return f'{window["w"]}×{window["h"]}'

    def bounds(window: dict) -> tuple[float, float, float, float]:
        return window["x"], window["y"], window["w"], window["h"]

    def around(window: dict) -> tuple[float, float, float, float]:
        """The panel plus a margin, from the top of the display (so the menu bar is included)."""
        return window["x"] - margin, display.y, window["w"] + 2 * margin, window["y"] + window["h"] + margin - display.y

    def capture(name: str) -> tuple[dict, Frame]:
        return steady(menubar, lambda window: (window, capture_screen(name, bounds(window))))

    def resize(edge: str, dx: float, dy: float) -> tuple[dict, dict]:
        return steady(menubar, lambda window: (window, drag_edge(pid, window, display, edge, dx, dy)))

    with Backdrop(display, menubar):
        natural, opaque = capture("panel-opaque")
        record(section, "默认大小为内容的理想尺寸", natural["w"] == 660, size(natural), "宽 660 pt，与改版前一致")

        # How much of the backdrop shows through: compare the panel's area with the backdrop alone.
        inner = (natural["x"] + 24, natural["y"] + 24, natural["w"] - 48, natural["h"] - 48)
        close_dashboard(menubar)
        time.sleep(0.6)
        behind = capture_screen("panel-behind", bounds(natural))

        def fade(window: dict) -> tuple[dict, Path]:
            slider = transparency_slider(pid, window)

            def act() -> None:
                for step in [0.15, 0.3, 0.45, 0.6, 0.75, 0.9, 0.75, 0.6]:
                    set_transparency(pid, window, display, step, slider)
                    time.sleep(0.15)
            return window, record_during("fade", act, pad=0.6)[0]

        window, video = steady(menubar, fade)
        value = float(read_default("dashboardTransparency") or 0)
        shown = f"{round(value * 100)}%"
        tree = dashboard_texts(pid, window)
        record(section, "点击仪表盘底栏滑块调节透明度", abs(value - 0.6) <= 0.03 and f'"{shown}"' in tree,
               f"dashboardTransparency = {value:.3f}，底栏显示 {shown}", "目标 60%")
        gif(video, display, around(window), SHOTS / "live-transparency.gif", menubar=menubar)
        time.sleep(1.5)
        window, clear = capture("08-dashboard-transparent")
        crop(clear, SHOTS / "08-dashboard-transparent.png", around(window), menubar=menubar)
        before = mean_difference(region_rgb(opaque, inner), region_rgb(behind, inner))
        after = mean_difference(region_rgb(clear, inner), region_rgb(behind, inner))
        record(section, "背后的壁纸透过面板显现 (像素对比)", after < before * 0.7,
               f"面板区域与纯背景的平均色差 {before:.1f} → {after:.1f}", f"透明度 0% → {shown}，越小越接近背景")

        # Resizing: the bottom-right corner, then single edges, down to the minimum.
        def grow(window: dict) -> tuple[dict, Path, dict]:
            video = record_during("resize", lambda: drag_edge(pid, window, display, "corner", 220, 140, 1200), pad=0.6)[0]
            return window, video, dashboard_window() or window

        window, video, grown = steady(menubar, grow)
        record(section, "拖动右下角放大面板",
               (grown["w"], grown["h"]) == (window["w"] + 220, window["h"] + 140) and (grown["x"], grown["y"]) == (window["x"], window["y"]),
               f"{size(window)} → {size(grown)}，左上角不动", "拖动 +220, +140")
        saved = (read_default("dashboardWidth"), read_default("dashboardHeight"))
        record(section, "新尺寸写入偏好设置", saved == (str(grown["w"]), str(grown["h"])), " × ".join(saved))
        gif(video, display, (window["x"] - margin, display.y, grown["w"] + 2 * margin,
                             grown["y"] + grown["h"] + margin - display.y), SHOTS / "live-resize.gif", menubar=menubar)
        time.sleep(1.5)
        grown, frame = capture("09-dashboard-resized")
        crop(frame, SHOTS / "09-dashboard-resized.png", around(grown), menubar=menubar)

        grown, wider = resize("left", -120, 0)
        expected = min(grown["w"] + 120, grown["x"] + grown["w"] - (display.x + 8))
        record(section, "拖动左边缘加宽，右边缘不动", wider["w"] == expected and wider["x"] + wider["w"] == grown["x"] + grown["w"],
               f"{size(grown)} → {size(wider)}")
        wider, short = resize("bottom", 0, 100 - wider["h"])
        short, shorter = resize("bottom", 0, -150)
        record(section, "拖动下边缘缩小，停在内容的最小高度", short["h"] < natural["h"] and shorter["h"] == short["h"]
               and short["y"] == wider["y"], f'{size(wider)} → {size(short)}，再上拖 150 pt 仍为 {shorter["h"]}',
               f'最小高度小于默认的 {natural["h"]}')
        shorter, narrow = resize("right", 100 - shorter["w"], 0)
        record(section, "拖动右边缘缩小，停在最小宽度，左边缘不动", narrow["w"] == MIN_WIDTH and narrow["x"] == shorter["x"],
               f"{size(shorter)} → {size(narrow)}", f"最小宽度 {MIN_WIDTH}")
        time.sleep(1.5)
        narrow, frame = capture("10-dashboard-minimum")
        crop(frame, SHOTS / "10-dashboard-minimum.png", around(narrow), menubar=menubar)
        tree = dashboard_texts(pid, narrow)
        complete = all(t in tree for t in ('"CPU"', '"GPU"', '"内存"', '"网络"', '"温度与风扇"', "AXSlider (透明度)", "AXButton (退出)"))
        record(section, "最小尺寸下内容完整 (界面文本)", complete, "5 类卡片、透明度滑块、底栏按钮都在")

        close_dashboard(menubar)
        window = open_dashboard(menubar)
        record(section, "关闭后重新打开，保持上次的大小", (window["w"], window["h"]) == (narrow["w"], narrow["h"]),
               size(window), f"上次 {size(narrow)}")
        value = steady(menubar, lambda window: set_transparency(pid, window, display, 0))
        record(section, "滑块调回 0%", value == 0, f"dashboardTransparency = {value:g}")

    # The settings window shows both values and can put the size back.
    window = open_dashboard(menubar)
    settings = open_settings(pid, window)
    record(section, "从仪表盘打开设置窗口", bool(settings), "已打开" if settings else "未打开")
    if not settings:
        return
    tree = dashboard_texts(pid, settings)
    listed = f'{window["w"]} × {window["h"]}'
    record(section, "设置窗口显示当前面板大小与透明度", listed in tree and '"0%"' in tree, f"面板大小 {listed}，透明度 0%")
    reset = ax_press(pid, settings["id"], r'\[(\d+)\] AXButton[^\n]*恢复默认')
    time.sleep(1)
    cleared = read_default("dashboardWidth") == "" and read_default("dashboardHeight") == ""
    ax_press(pid, settings["id"], r'\[(\d+)\] AXButton \[actions=\[press\]\]\n\s*- \[\d+\] AXButton \[actions=\[press,showmenu\]\]')
    wait_until(lambda: not any(w["layer"] == 0 and w["onscreen"] for w in windows("BarPulse")), 5)
    window = open_dashboard(menubar)
    close_dashboard(menubar)
    record(section, "设置里「恢复默认」后回到默认大小", reset and cleared and (window["w"], window["h"]) == (natural["w"], natural["h"]),
           size(window), f'默认 {size(natural)}')


# ---------------------------------------------------------------- report

def write_report(info: dict) -> None:
    lines = [
        "# BarPulse 端到端验证报告",
        "",
        f"- 时间：{time.strftime('%Y-%m-%d %H:%M:%S')}",
        f"- 机器：{info['chip']} · {info['cpuCores']} 核 CPU · {info.get('gpuCores')} 核 GPU · {info['memory'] / 1024 ** 3:.0f} GB · {info['osVersion']}",
        "- 截图来源：Cua Driver 的 ScreenCaptureKit 整屏录制（真实屏幕像素，非离屏渲染）",
        "- 交互方式：通过菜单栏 (MenuBarAgent) 的辅助功能树按下 BarPulse 状态栏项，与鼠标点击走同一路径；"
        "透明度滑块和面板边缘用直接投递给 BarPulse 的鼠标事件 (CGEvent) 点击、拖动，不移动系统指针",
        "- 只在 Cua Driver 录制的副显示器上操作：仪表盘、设置窗口和背景板都不出现在主显示器上，也不抢键盘焦点",
        "- 仪表盘截图时在面板后面铺一张系统自带壁纸 (Sonoma)，透过玻璃看到的是固定画面而不是当时打开的窗口",
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
        ("08-dashboard-transparent", "透明度 60%（底栏滑块拖动后）"),
        ("09-dashboard-resized", "拖动右下角放大后的仪表盘（图表随之变大）"),
        ("10-dashboard-minimum", "最小尺寸"),
    ]
    lines += ["## 截图", ""]
    for name, title in shots:
        if (SHOTS / f"{name}.png").exists():
            lines += [f"### {title}", "", f"![{title}](screenshots/{name}.png)", ""]
    for name, title in [("live-transparency", "调节透明度 0% → 90% → 60%"), ("live-resize", "拖动右下角调整大小")]:
        if (SHOTS / f"{name}.gif").exists():
            lines += [f"### {title}", "", f"![{title}](screenshots/{name}.gif)", ""]
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
