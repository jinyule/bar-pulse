# BarPulse

原生 macOS 菜单栏系统监视器：在菜单栏实时显示 **CPU、GPU、内存、网速、温度**，点击后展开一个 Liquid Glass 风格的仪表盘。

纯 Swift 实现，菜单栏用 AppKit 自绘，仪表盘用 SwiftUI；数据直接取自内核与 IOKit，没有任何第三方依赖。

![仪表盘](verification/screenshots/02-dashboard.png)

![菜单栏](verification/screenshots/01-menubar-zoom.png)

## 功能

- **菜单栏**：双行紧凑或单行图标两种样式，可选彩色或单色指示条；宽度只由固定模板决定，数值变化时不会抖动；文字颜色随菜单栏外观（浅色、深色、壁纸着色）自动适配
- **CPU**：总占用、用户/系统拆分、负载均值，按核心簇（超级核 / 性能核 / 能效核）分组的逐核柱状图，90 秒历史曲线
- **GPU**：设备、渲染器、拼贴器利用率，显存占用，历史曲线
- **内存**：与活动监视器口径一致的应用内存、联动内存、被压缩、已缓存文件，内存压力，交换区
- **网络**：上下行速率、上下镜像历史图、主接口名称与 IP、本次会话流量
- **温度与风扇**：CPU（均值和最热核心）、GPU、内存、SoC 晶粒、SSD、电池温度，热状态，风扇转速（在 2 个风扇的机型上实测）
- **设置**：菜单栏指标开关、样式、刷新频率（1/2/3/5 秒）、仪表盘外观、°C/°F、登录时启动，并带有和菜单栏像素一致的实时预览
- 右键状态栏项可打开快捷菜单（仪表盘、活动监视器、设置、退出）
- 自身开销很低：面板关闭时约 0.9% CPU（单核）、内存不到 50 MB；仪表盘打开时约 8% CPU、150 MB。仪表盘只在打开期间存在，风扇转动和实时脉冲点交给 Core Animation 在渲染服务器里播放，不占用应用的 CPU

## 构建与运行

需要 macOS 14 或更高版本，以及 Xcode 16 或更高版本（Swift 6 工具链）。

```bash
scripts/build-app.sh            # 生成并签名 build/BarPulse.app
open build/BarPulse.app         # 运行（菜单栏应用，不显示在程序坞中）
cp -R build/BarPulse.app /Applications/   # 可选：安装
```

构建脚本会自动选择钥匙串中的 Apple Development 或 Developer ID 证书签名，找不到时退回到临时（ad-hoc）签名。

`BarPulse --dump [--interval 秒]` 会以无界面方式输出一次完整采样的 JSON；加上 `--watch` 则每次采样输出一行，方便脚本对接。

## 数据来源

| 指标 | 接口 | 说明 |
|---|---|---|
| CPU | `host_processor_info` | 逐核 tick 差分；`hw.perflevelN.*` 用于识别核心簇 |
| 内存 | `host_statistics64(HOST_VM_INFO64)`、`vm.swapusage`、`kern.memorystatus_vm_pressure_level` | 与活动监视器同口径 |
| 网络 | `sysctl` `IFMIB_IFDATA` | 64 位精确计数。`NET_RT_IFLIST2` 在新版 macOS 上会把字节数截断为 32 位并按 1 KiB 取整，所以没有使用 |
| GPU | IOAccelerator `PerformanceStatistics` | 无需特权 |
| 温度/风扇 | AppleSMC（只读）+ IOHIDEventSystem | `Tp*`/`Tg*`/`Tm*` 键，以及 `PMU tdie*`、`NAND`、电池传感器 |
| 热状态 | `ProcessInfo.thermalState` | |

温度读取用到了 IOHIDEventSystem 的私有函数（运行时通过 `dlsym` 加载），并需要访问 SMC，因此应用不开沙盒，无法上架 Mac App Store。

## 端到端验证

```bash
scripts/verify.sh           # 完整验证（约 6 分钟，需要 Cua Driver 拥有屏幕录制和辅助功能权限）
scripts/verify.sh --no-ui   # 只做指标校验，不截图
```

验证脚本依次执行：

1. 单元测试（格式化、SMC 解码、各采样器的实时检查）
2. 构建并签名 `.app`
3. 指标交叉校验：与 `top`（6 秒并行采样取均值）、`vm_stat`、`sysctl`、`netstat -ibn`、`ioreg` 对比
4. 负载响应：用 `yes` 打满 CPU（同时检查温度上升）、用 Metal 计算着色器打满 GPU、多源并行下载，逐个 1 秒窗口与 netstat 的同窗口增量对比
5. 真实界面：通过菜单栏（MenuBarAgent）的辅助功能树按下 BarPulse 状态栏项，与鼠标点击走同一条路径；用 ScreenCaptureKit 录屏并截取真实屏幕画面（从每段录像中挑选动画已经结束的稳定帧）；读取仪表盘的辅助功能文本，核对界面显示值与采样值是否一致；分别在面板关闭和打开时测量应用自身的 CPU 与内存开销；从仪表盘按钮打开设置窗口，在设置窗口里实时切换单行样式、单色样式和深色外观并截图（不重启应用，同时验证设置即时生效）

界面验证需要解锁的屏幕，运行期间请不要操作鼠标键盘。状态栏项总是出现在鼠标所在显示器的菜单栏里（在带刘海的笔记本屏幕上可能被收进溢出区），所以脚本会先把鼠标移到 Cua Driver 录制的那块显示器边缘，结束后再移回原位。

结果写在 [`verification/README.md`](verification/README.md)，截图保存在 `verification/screenshots/`。

## 目录结构

```
Sources/BarPulseCore/   采样器（CPU / 内存 / 网络 / GPU / SMC / HID / 温度）、格式化、历史缓冲
Sources/BarPulse/       应用：状态栏自绘视图、弹出面板、SwiftUI 仪表盘、设置
Tests/                  单元测试与实机采样测试
scripts/                构建、图标生成、端到端验证
```

## 许可证

[MIT](LICENSE)
