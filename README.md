# BBK H1 USB 兼容设置

针对步步高 H1 在 Windows 上反复连接、断开的一种兼容处理：使用现有 USBSTOR 驱动的按设备兼容开关，跳过初始化时的增强存储安全功能探测。

**已验证：H1 系统 1.41、Windows 10 Pro x64 19045、USBSTOR.sys 10.0.19041.4355、Intel Z590 xHCI 主机控制器及 VIA USB 集线器。** 其他 Windows/驱动版本、其他 H1 固件、其他机型尚未验证。本项目处理的是下述具体故障，不能解决所有 USB 断线问题。

## 故障原因与证据

故障时，电脑已加载 Microsoft USBSTOR 驱动，但 H1 存储不断消失、重新枚举，H1 屏幕可能仍显示连接。

2026-10-04 的本机诊断发现：

- 失败抓包包含 94 次 `SECURITY PROTOCOL IN`（SCSI 操作码 `0xA2`）查询，CDB 为 `A20000000000000000080000`，要求读取 8 字节。
- 内置 NAND 与 SD 卡槽两个逻辑单元都受影响；94 次读取全部报 `USBD_STATUS_BABBLE_DETECTED`（`0xC0000012`），故障阶段事件追踪还显示端口重置和重新枚举。
- 同一记录中的 `READ CAPACITY`（`0x25`）能够正常返回容量数据，失败点并非此前猜测的容量查询。
- 异常包的数据未被控制器上交，因此无法断言 H1 实际返回了多少字节，也未将问题进一步定位到某一条固件指令或主机控制器缺陷。
- 临时移除磁盘类 `EhStorClass` 注册项的对照实验没有消除故障，测试后已恢复原设置。

检查本机 USBSTOR.sys 代码，确认它在逻辑单元创建前发出安全协议探测，并读取 `Control\USBSTOR\VIDPID` 下的 `DeviceHackFlags`；其中 `0x20000000` 分支跳过该初始化探测。系统自带的一个其他设备兼容项也使用这一数值。

该位的作用由**本机驱动静态代码检查与实际抓包**验证；本项目不声称它是 Microsoft 已公开文档化、跨版本保证不变的接口。

启用后，约 3 分钟抓包覆盖完整重新开机后的连接及保持开机时再次拔插连接，两次初始化均成功，`0xA2` 探测为 0 次，USB bulk 传输错误为 0 次。内置存储和 SD 卡正常挂载，同一文件连续 6 次真实读取及 SHA256 校验一致。**只验证了文件读取和重新连接，未验证写入、刷机或长时间运行。**

此前曾偶尔自行恢复；那次只保留了传输头，无法确认具体是哪条初始化命令或恢复路径成功，不能据此解释每一次偶发恢复。

## 启用兼容设置

1. 下载仓库 ZIP 并解压到一个可保留的位置，或使用 `git clone`。
2. 拔下 H1 的 USB，打开“以管理员身份运行”的 PowerShell，进入解压目录。
3. 首次运行可先预览：

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\set-h1-compatibility.ps1 -WhatIf
   ```

4. 启用：

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\set-h1-compatibility.ps1
   ```

5. 接回 H1，选择 USB 连接。若设备仍退出连接界面，可先拔线，将 H1 完整关机、开机后再连接；本次实测中这样恢复后，普通再次拔插也成功。

`-ExecutionPolicy Bypass` 仅作用于这次 PowerShell 进程，脚本不修改系统执行策略。使用此脚本不需要安装 USBPcap 或新设备驱动，脚本也不会自动重启电脑。

## 恢复原设置

在同一 Windows 安装、同一脚本目录，以管理员身份执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\set-h1-compatibility.ps1 -Restore
```

然后重新插拔 H1。恢复原行为后，原来的断线问题可能再次出现。

首次启用时，脚本在旁边保存 `h1-compatibility-original.json`。请保留此文件；它记录**首次启用前**的状态，重复启用不会覆盖它。默认运行用于启用，`-Restore` 用于恢复；同一个脚本可重复启用、恢复，已处于目标状态时不重复写注册表。

恢复行为：

- 原值存在：还原原始 DWORD 数值。
- 原值不存在：删除本次新增的 `DeviceHackFlags`。
- 原键也不存在：仅在键已完全为空时删除它，保留后来新增的其他值或子键。
- 备份缺失、无效、属于其他 Windows 安装，或标志值被其他程序改动：拒绝覆盖并报错。

新的备份绑定 Windows 安装标识。脚本也兼容原始诊断创建的旧格式备份；旧备份没有安装标识，应由用户确保来自同一 Windows 安装。不要把本机备份复制给其他电脑使用。

## 修改内容与影响范围

唯一的兼容设置：

```text
HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\USBSTOR\07C4A4A5
DeviceHackFlags  REG_DWORD  0x20000000
```

若已有其他兼容位，脚本按位合并 `0x20000000` 并保留原有位；若存在相冲突的强制探测位 `0x10000000`，则拒绝启用。

| 范围 | 行为 |
| --- | --- |
| 本电脑上 VID `07C4`、PID `A4A5` 的 USBSTOR 设备 | 都匹配，包括同标识的另一台 H1；不限 USB 接口或序列号 |
| 通过 H1 暴露的内置 NAND 与 SD 卡槽 | 都受该设备初始化兼容处理影响 |
| 其他 VID/PID 的 USB 设备、内置磁盘 | 不匹配此设置 |
| 初始化时的增强存储探测 | 跳过；这些设备不会经该路径发现 IEEE 1667 等存储安全功能 |
| 普通文件访问 | 仍使用原来的 Windows 存储驱动；读取及再次连接已实测通过 |
| 第三方程序主动发送 `0xA2` | 不拦截所有 SCSI 命令，仍可能触发故障 |
| 刷机模式或其他 VID/PID | 不匹配；刷机未验证 |
| H1 固件与已有文件 | 脚本不写入或刷写设备，不格式化、不删除文件 |
| 持久性 | 设置保存在这台电脑，重启后保留；执行恢复后撤销；换电脑需分别设置 |

脚本不修改全局 USB 电源设置、磁盘类过滤驱动列表、USBSTOR 驱动文件或服务启动类型。它也不安装、停用或卸载 USBPcap。诊断电脑上曾单独安装 USBPcap 来定位问题，抓包工具与此兼容开关是两件事。

## 检查当前设置

```powershell
reg.exe query "HKLM\SYSTEM\CurrentControlSet\Control\USBSTOR\07C4A4A5" /v DeviceHackFlags
```

全新配置中启用后的值为 `0x20000000`。恢复后，如果该值原本不存在，查询提示找不到值是正常结果。

## 脚本行为测试

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test-compatibility.ps1
```

测试在 HKCU 下建立独立临时键，覆盖启用、重复启用、恢复、重新启用、保留原值及其他键值、外部修改冲突、缺失备份和 `-WhatIf` 行为；不改变真实 H1 的 HKLM 配置，也不需要管理员权限。

仓库只发布脚本、README、测试与忽略规则。原始抓包、驱动反汇编、安装包、本机备份及设备文件均不包含在仓库中。

## 参考资料

- [Microsoft USBSTOR 设备标识生成说明](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/identifiers-generated-by-usbstor-sys)
- [Microsoft 增强存储过滤驱动说明](https://learn.microsoft.com/en-us/windows-hardware/drivers/storage/ehstor-driver)
- [Microsoft USB/SCSI 状态及命令头文件](https://github.com/microsoft/win32metadata/tree/main/generation/WinSDK/RecompiledIdlHeaders/shared)
- [USBPcap 捕获限制：URB 抓包不同于物理总线分析](https://desowin.org/usbpcap/capture_limitations.html)
