# BarPulse 端到端验证报告

- 时间：2026-10-29 09:42:27
- 机器：Apple M5 Pro · 18 核 CPU · 20 核 GPU · 64 GB · macOS 27.0.1
- 截图来源：Cua Driver 的 ScreenCaptureKit 整屏录制（真实屏幕像素，非离屏渲染）
- 交互方式：通过菜单栏 (MenuBarAgent) 的辅助功能树按下 BarPulse 状态栏项，与鼠标点击走同一路径

## 指标交叉校验

| 结果 | 检查项 | BarPulse | 参考值 |
|---|---|---|---|
| ✅ | CPU 总占用 vs top (6 秒均值) | 10.1% | top 9.8%，8 / 6 个 1 秒窗口 |
| ✅ | 内存已使用 vs vm_stat | 50.66 GB | vm_stat 50.66 GB |
| ✅ | 内存总量 vs hw.memsize | 64.00 GB |  |
| ✅ | 交换区 vs vm.swapusage | 2.48 GB | sysctl 2.48 GB |
| ✅ | 网络累计接收 vs netstat -ibn | 218.23 GB | netstat 218.23 GB |
| ✅ | 主网络接口 | Wi-Fi (en0)，本机 IP 已获取 |  |
| ✅ | GPU 统计可读 (IOAccelerator) | 16%，显存占用 1.42 GB | ioreg 14% |
| ✅ | 温度传感器读数合理 (15–110°C) | cpu=57.2°C，gpu=54.9°C，memory=55.9°C，soc=52.8°C，ssd=42.0°C，battery=34.4°C |  |
| ✅ | 风扇转速 (SMC) | 风扇1 2318 RPM (范围 2317–7826)，风扇2 2504 RPM (范围 2317–7826) |  |

## 负载响应测试

| 结果 | 检查项 | BarPulse | 参考值 |
|---|---|---|---|
| ✅ | CPU 满载 (18 个 yes 进程) | 97.7% |  |
| ✅ | 满载后 CPU 温度上升 | 57.2°C → 67.6°C |  |
| ✅ | GPU 负载 (Metal 计算着色器) | 100% | ioreg 100% |
| ✅ | 下载速率 vs netstat 同窗口增量 | 均值 8.36 MB/s，峰值 9.61 MB/s | netstat 均值 8.40 MB/s，12 个 1 秒窗口，偏差 1.8% |

## 界面端到端

| 结果 | 检查项 | BarPulse | 参考值 |
|---|---|---|---|
| ✅ | 状态栏项出现在菜单栏 (MenuBarAgent AX) | pid 77808 |  |
| ✅ | 点击状态栏项打开仪表盘 | 面板中心 x=2998 |  |
| ✅ | BarPulse 自身开销 (面板关闭，top 12 秒均值) | CPU 0.85%，内存 43 MB | 阈值 CPU < 3%，内存 < 100 MB |
| ✅ | 负载期间仪表盘 CPU 读数 (界面文本) | 69% | dump 60% |
| ✅ | 仪表盘内存读数与采样一致 (界面文本) | 51.2 GB | dump 51.1 GB |
| ✅ | 仪表盘网络接口 (界面文本) | Wi-Fi · en0 |  |
| ✅ | 仪表盘包含 5 类指标卡片 | CPU / GPU / 内存 / 网络 / 温度与风扇 |  |
| ✅ | BarPulse 自身开销 (面板打开，top 12 秒均值) | CPU 8.93%，内存 149 MB | 阈值 CPU < 12%，内存 < 250 MB |
| ✅ | 点击「设置」打开设置窗口 | 460×723 |  |
| ✅ | 设置切换「单行图标」样式，菜单栏即时生效 | 状态栏项中心 2998 → 2946 | screenshots/06-menubar-inline-zoom.png |
| ✅ | 设置关闭「彩色指示条」，菜单栏即时生效 | colorful = 0 | screenshots/07-menubar-monochrome-zoom.png |
| ✅ | 关闭设置窗口 | 已关闭 |  |
| ✅ | 设置切换深色仪表盘 | appearance = dark | screenshots/05-dashboard-dark.png |

## 截图

### 菜单栏状态项放大

![菜单栏状态项放大](screenshots/01-menubar-zoom.png)

### 仪表盘（图表含一次负载事件）

![仪表盘（图表含一次负载事件）](screenshots/02-dashboard.png)

### CPU + GPU + 网络同时加压时的仪表盘

![CPU + GPU + 网络同时加压时的仪表盘](screenshots/03-dashboard-under-load.png)

### 加压时的菜单栏

![加压时的菜单栏](screenshots/03-menubar-under-load-zoom.png)

### 设置窗口（含菜单栏实时预览）

![设置窗口（含菜单栏实时预览）](screenshots/04-settings.png)

### 深色外观

![深色外观](screenshots/05-dashboard-dark.png)

### 单行图标样式

![单行图标样式](screenshots/06-menubar-inline-zoom.png)

### 单色样式

![单色样式](screenshots/07-menubar-monochrome-zoom.png)

实时刷新动图：[live-menubar.gif](screenshots/live-menubar.gif) · 视频：[live-dashboard.mp4](screenshots/live-dashboard.mp4)
