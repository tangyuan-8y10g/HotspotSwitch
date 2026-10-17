# HotspotSwitch · Windows 移动热点开关

> 设置页的「移动热点」开关是灰的、点不动？用宽带拨号（PPPoE）上网时开不了热点？
> 这个小工具绕过那条限制，直接调用系统接口把热点开起来。

## 症状自查

- 设置 → 网络和 Internet → 移动热点，开关**灰色点不动**
- 点开关提示「未建立以太网、Wi-Fi 或手机网络数据连接」
- 开关能点开，但手机连上后打不开网页
- 无线网卡被禁用，导致热点不可用

## 为什么会出现这个问题

Windows 设置页判断「能不能开热点」时，只认 **以太网 / Wi-Fi / 手机网络** 三种接入方式，
识别不到 **宽带拨号（PPPoE）** 连接，于是直接把开关置灰。

但底层接口其实完全可用。实测在拨号环境下：

```
GetTetheringCapabilityFromConnectionProfile()  ->  Enabled
StartTetheringAsync()                          ->  Success
```

热点正常广播，系统还会自动配好 ICS 共享（虚拟网卡拿到 `192.168.137.1`）。

**能力是有的，只是设置页不给点。** 这个工具就是绕过去。

## 功能

- **一键开关**：不依赖那个灰掉的开关，直接调系统接口
- **复制密码**：面板上点一下名称/密码即可复制
- **改名称密码**：真正写入系统热点配置，立即生效
- **一键修复**：自动启用被禁用的无线网卡、拉起 `WlanSvc` / `icssvc` / `SharedAccess` 服务，再尝试开热点
- **诊断报告**：系统版本、连接类型、无线网卡、服务状态、ICS 地址一次列清，方便求助时贴出来
- **纯本地**：无安装、无后台常驻、无联网、不上报任何数据

## 使用

下载后解压，双击：

| 文件 | 作用 |
| --- | --- |
| `HotspotSwitch.cmd` | **打开操作面板**（主入口） |
| `ON-start.cmd` | 直接开热点 |
| `OFF-stop.cmd` | 直接关热点 |
| `HotspotSwitch.ps1` | 核心脚本（面板与命令行共用） |
| `使用说明.txt` | 详细说明与常见问题 |

面板里能看到状态、热点名称、密码、已连设备数，以及「开启/关闭」「修改名称密码」「一键修复」三个操作。

## 命令行用法

```powershell
# 开关 / 切换 / 查询
powershell -ExecutionPolicy Bypass -File "HotspotSwitch.ps1" -On
powershell -ExecutionPolicy Bypass -File "HotspotSwitch.ps1" -Off
powershell -ExecutionPolicy Bypass -File "HotspotSwitch.ps1" -Toggle
powershell -ExecutionPolicy Bypass -File "HotspotSwitch.ps1" -Status

# 诊断 / 自动修复
powershell -ExecutionPolicy Bypass -File "HotspotSwitch.ps1" -Diag
powershell -ExecutionPolicy Bypass -File "HotspotSwitch.ps1" -Repair

# 修改热点名称和密码（密码至少 8 位）
powershell -ExecutionPolicy Bypass -File "HotspotSwitch.ps1" -SetSsid "hotpot" -SetPassword "12345678"
```

配合 `-NoGui`（不弹窗只打印）和 `-Quiet`（完全静默），可以写进**任务计划程序**实现开机/拨号后自动开热点。

## 兼容性

| 项目 | 要求 |
| --- | --- |
| 系统 | Windows 10 / 11（Win7 没有移动热点功能，不支持） |
| PowerShell | 系统自带的 **Windows PowerShell 5.1** |
| 权限 | 普通用户即可；「一键修复」里的启用网卡/启动服务需管理员，失败不影响开热点 |
| 依赖 | 无。不需要安装任何运行时 |

> ⚠️ 请**不要**用 PowerShell 7 / `pwsh` 运行，它不支持本工具依赖的 WinRT 类型投影。

## 已知限制

- 热点不会开机自启（用任务计划程序可解决）
- 电脑必须已经真正联网后才能开热点
- 若手机连上却上不了网，先关掉代理软件的 **TUN 模式**（如 Clash），或临时断开 VPN
- 部分老无线网卡驱动不支持「承载网络」，这种情况无解，换 USB 无线网卡即可

## 原理速览

```
GetTetheringCapabilityFromConnectionProfile()   查询能否共享
StartTetheringAsync() / StopTetheringAsync()    启停热点
ConfigureAccessPointAsync()                     修改名称与密码
```

全部通过 `Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager` 完成。
脚本会优先用 `GetInternetConnectionProfile()` 取当前联网连接；取不到时再遍历所有连接配置，
选一个热点能力为 `Enabled` 的——所以不依赖具体连接名（「宽带连接」「以太网」「WAN Miniport」都能认）。

## License

[MIT](LICENSE)

---

**English summary**: A tiny Windows tool that turns the mobile hotspot on/off by calling
`NetworkOperatorTetheringManager` directly, bypassing the greyed-out toggle in Settings that
happens when the PC connects via PPPoE / broadband dial-up. No installation, no dependencies,
UI + CLI, plus a one-click repair and a diagnostic report. Windows 10/11, Windows PowerShell 5.1.
