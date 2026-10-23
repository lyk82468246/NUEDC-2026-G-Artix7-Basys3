# UTG932 / UTG932E 控制脚本

后续已完成[首次接入FPGA的三分量实测](utg_multitone_hardware_20261023.md)：新增固定100mVpp安全包络试验入口 `scripts/instruments/utg_fpga_trial.py`，默认dry-run。普通三音与弱基波/强谐波案例均正确提取50kHz基频；本页原“未开启输出”等描述仅对应最初驱动验证阶段，不覆盖后续硬件试验。固定试验替换助手先前创建的用户槽1，不默认用户的其他槽位可覆盖。

入口为 `scripts/utg932.ps1`；底层为 `scripts/instruments/utg932.py`，同时提供 Python `UTG932` 类。沿用项目的设备独占锁，和 HDS242S 使用不同锁、不同传输层。

## 本机连接检查（2026-10-23）

用户安装完成后，已确认项目虚拟环境中存在 **PyVISA 1.16.2**，NI-VISA DLL 和 IVI USBTMC 驱动正常，PnP 状态 Started。实际资源为 `USB0::0x6656::0x0834::2819216557::INSTR`；`*IDN?` 返回 `UNI-T Technologies,UTG900,2819216557,1.09`。固件只返回系列名，UTG932 具体型号以用户提供信息及铭牌为准。

已通过实机身份/双通道查询、正弦/方波/脉冲/斜坡/DC 的 OFF 配置回读、非零偏置、任意波形上传和槽位选择、屏幕下载，以及一条 `arb` 命令完成上传与配置。4000 点双音表 `TwoTone` 已上传到用户槽 1；屏幕显示其自定义波形。**未开启输出，未测量实际端口电压/频谱，也未将此次测试当作幅值校准或多音 FPGA 验收。**

实机发现：V1.09 文本回复通过 USBTMC EOM 结束，末尾没有 LF。脚本设置 `read_termination=None`，写命令仍以 LF 结束。强制等待 LF 会造成真实身份查询超时。DC 模式下写频率曾回读为 1 μHz，故 DC 配置不设置/核对无物理意义的频率和相位，只核对有效电平等参数。

测试收尾已恢复：CH1 正弦 400 kHz、100 mVpp、0 V、HIGHZ、OFF；CH2 正弦 1 kHz、100 mVpp、0 V、50 Ω、OFF。用户槽 1 保留 `TwoTone`。

## 环境准备

本机已安装，不需重复安装。其他电脑按厂商手册使用 [NI-VISA](https://www.ni.com/en/support/downloads/drivers/download.ni-visa.html)（包含 USB 仪器支持）和 PyVISA。选择适合目标 Windows 的版本；安装程序可能需要管理员权限或重启。

PyVISA 是 Python 包，不包含系统 USB 驱动。HDS242S 使用现有 OWON/libusb0；不需要将它改为 VISA 驱动。UTG932 的驱动操作应针对 `6656:0834`。

工程根目录的 PowerShell：

```powershell
# 使用已有项目环境；如果环境尚不存在，先执行 python -m venv .venv-hds
.\.venv-hds\Scripts\python.exe -m pip install -r scripts/instruments/requirements-utg932.txt
.\scripts\utg932.ps1 diagnose
.\scripts\utg932.ps1 identify
.\scripts\utg932.ps1 status
```

`diagnose` 仅读 Windows 设备与 VISA 资源，不发送仪器命令。没有可用 UTG 资源时退出码为 1。`identify` 和 `status` 只查询，不改输出；关闭这类查询会话也不改输出。

Codex 的受限子进程可能无法使用已经安装的 VISA 依赖库，出现 `VI_ERROR_LIBRARY_NFOUND`，这不等于缺少 PyVISA 或驱动；本次在允许访问系统运行库的执行环境中通信成功。NI-VISA 还曾提示 `VI_WARN_CONFIG_NLOADED`，使用默认配置后实际资源发现、上传及回读均成功。

自动发现只匹配 `6656:0834` 的 USB INSTR，不探测其他仪器。多台 UTG 时必须指定 `--resource`。打开后先检查厂商和型号；允许 UTG932/UTG932E 及手册中使用的系列名 UTG900。系列名返回值不能独立证明具体子型号，须同时核对铭牌。示例中的资源仅用于展示格式，以 `diagnose` 的实际结果为准：

```powershell
.\scripts\utg932.ps1 --resource 'USB0::0x6656::0x0834::2819216557::INSTR' status
```

## 任意波形与多音：推荐入口

支持自己提供归一化采样点，不局限于预置函数。JSON 可以是数组或包含 `samples` 的对象；CSV/TXT 为单列数值，无表头，可有 `#` 注释。每周期 2～4000 点，数值必须在 [-1, 1]，不自动削顶或重新归一化。

生成示例双音（100 kHz/100 mVpp + 189.5 kHz/50 mVpp），再一条命令上传配置：

```powershell
.\scripts\utg932.ps1 multitone scripts/instruments/utg932_multitone_example.json --save test_results/my_twotone.json
.\scripts\utg932.ps1 arb test_results/my_twotone.json --channel 1 --slot 1 --name TwoTone --dry-run
.\scripts\utg932.ps1 arb test_results/my_twotone.json --channel 1 --slot 1 --name TwoTone
```

生成和 dry-run 都不访问硬件。`arb` 会关闭两路输出，覆盖指定用户槽，上传表格并配置目标通道，结束保持两路 OFF；不会自动 ON。槽位为 0/1，对应上传命令 WARB1/WARB2。名称限 1～16 个 ASCII 字母/数字/下划线，以字母开头。

输出仍须显式执行 `output on --channel 1`，结束执行 `output off --channel all`。上传会覆盖槽中的既有用户波形，使用前选择需要替换的槽位。

示例的整表重复频率为 **500 Hz**，不是 100 kHz：4000 点中分别存储 200 和 379 个周期，对应等效表采样率 2 MSa/s。生成器要求各音调为重复频率的整数倍，默认按各频率的最大公约数选择重复频率；拒绝不相干周期、表内混叠以及隐含幅值缩放。接近但公约数过小的频率组合可能无法在 4000 点内表示，会明确报错。

`vpp` 是 ±1 对应的满量程峰峰值；各分量按其电压比例写入表中。示例的满量程为 150 mVpp，并不将每个分量都设为 150 mVpp。实际表值的峰峰值为 `vpp*(max(samples)-min(samples))/2`。物理输出还受仪器带宽、采样插值和实际负载影响。

已有自己的采样文件时，明确指定整表重复频率与满量程：

```powershell
.\scripts\utg932.ps1 arb my_wave.csv --channel 1 --slot 0 --name Custom --hz 1000 --vpp 0.1 --offset-v 0
```

生成的 JSON 自带 `repeat_hz/vpp/offset_v`，`arb` 自动读取；命令行可显式覆盖它们，改变重复频率会同比改变所有分量频率。普通数组、CSV/TXT/BSV 不包含这类输出参数，必须提供 `--hz` 和 `--vpp`。

分开执行上传、选择和 BSV 编码也可以：

```powershell
.\scripts\utg932.ps1 upload test_results/my_twotone.json --slot 1 --name TwoTone
.\scripts\utg932.ps1 configure --waveform arb --slot 1 --hz 500 --vpp 0.15 --load HIGHZ
.\scripts\utg932.ps1 encode test_results/my_twotone.json --save test_results/my_twotone.bsv
```

BSV 使用 ASCII HEAD/DATA 段及 little-endian signed 16-bit 采样（-32767～32767），通过 `WARB` 后直接发送文件内容，不加 IEEE `#` 块封装。当前只接受本工具的归一化 BSV 头，拒绝未知缩放的外部 BSV。采用 4000 点上限是已参考并实测的兼容范围，不宣称覆盖仪器所有固件的最大记录长度。参考了[独立设备驱动作者公开的协议实现](https://github.com/renaatd/utg962/blob/main/utg962/utg962.py)，本工程独立实现。

## 预置波形与开关

先离线预览，不连接硬件：

```powershell
.\scripts\utg932.ps1 configure --channel 1 --waveform sine --hz 100000 --vpp 0.1 --offset-v 0 --load HIGHZ --dry-run
```

配置 CH1 为 100 kHz、100 mVpp、0 V 偏置、高阻显示，配置结束保持 CH1 OFF：

```powershell
.\scripts\utg932.ps1 configure --channel 1 --waveform sine --hz 100000 --vpp 0.1 --offset-v 0 --load HIGHZ
.\scripts\utg932.ps1 status --channel 1
```

明确开启／关闭输出：

```powershell
.\scripts\utg932.ps1 output on --channel 1
.\scripts\utg932.ps1 output off --channel 1
.\scripts\utg932.ps1 output off --channel all
```

**`output on` 成功后输出会持续开启，即使脚本已经退出。** 需要关闭时执行 OFF；Python 临时测量推荐使用 `try/finally`。改变 CH1 不会顺带关 CH2；`--channel all` 仅支持 OFF。

其他波形（均配置后保持所选通道 OFF）：

```powershell
# CH2：1 kHz 方波，1 Vpp，偏置 0.5 V，占空比 20%
.\scripts\utg932.ps1 configure --channel 2 --waveform square --hz 1000 --vpp 1 --offset-v 0.5 --duty 20
# 脉冲，占空比 25%
.\scripts\utg932.ps1 configure --waveform pulse --hz 1000 --vpp 0.1 --duty 25
# 对称斜坡；symmetry=50 对应三角波
.\scripts\utg932.ps1 configure --waveform ramp --hz 1000 --vpp 0.1 --symmetry 50
# 直流电平由 offset-v 指定；DC 不设置频率/相位，Vpp 不是其直流电平
.\scripts\utg932.ps1 configure --waveform dc --offset-v 0.1
```

需要命令记录时，将全局参数放在子命令前；目标文件必须不存在：

```powershell
.\scripts\utg932.ps1 --log test_results/utg932_status_001.json status
```

日志包含身份、资源、原始命令/回读和成功/失败。父目录须已存在。`--log` 用于真实仪器命令；`diagnose`、`configure --dry-run` 直接向终端输出 JSON。

## Python 调用与逐点测试

从 `scripts/instruments` 中的脚本导入 `from utg932 import UTG932`。从工程根目录运行的其他脚本，可先将该目录加入模块搜索路径：

```python
from pathlib import Path
import sys

sys.path.insert(0, str(Path("scripts/instruments").resolve()))
from utg932 import UTG932

with UTG932() as generator:
    print(generator.identity)
    print(generator.settings(1))
    try:
        for hz in (10000, 50000, 100000, 200000, 500000):
            generator.configure_sine({"hz": hz, "vpp": 0.1, "offset_v": 0}, channel=1)
            generator.output_on(1)
            # 在此等待电路稳定并调用已有 HDS242S / FPGA 采集接口。
            # 这是逐点设置示例，不宣称采集同步或完成校准。
    finally:
        shutdown = generator.emergency_off(1)
        if not shutdown["acknowledged"]:
            raise RuntimeError(f"手动关闭 CH1，软件无法确认 OFF：{shutdown}")
```

`with` 负责释放资源，不自动关闭输出；`finally` 明确承担临时测量的关断。UTG API 使用 Hz、Vpp、V、度和百分比。状态中 `raw` 保留原文；面板处于 VRMS/dBm 时 `vpp` 返回 `None`，`amplitude` 及 `unit` 保留实际单位。

Python 中上传自定义数组并选择它：

```python
with UTG932() as generator:
    generator.upload_arb([-1, -0.5, 0, 0.5, 1, 0.5, 0, -0.5], slot=0, name="Custom")
    generator.configure_arb(1, slot=0, hz=1000, vpp=0.1)
    # 此时仍 OFF；需要实际输出时单独调用 output_on(1)，并用 finally 关断。
```

当前是独立发生器接口，未更换 `lab_server.py` 的 HDS242S 后端，也未改变现有 HDS/FPGA 扫频流程。后续接入时可直接复用此类和 `configure_sine`。

## 配置与失败行为

- 配置先验证参数、关闭所选通道，再设连续模式、VPP、负载、波形和参数。每次设置后检查 OUT；最后回读模式、单位、负载、波形及数值。配置不会主动开启输出。
- ON 前重新读取当前设置并检查范围；失败则尝试 OFF。避免跨进程调用时依赖旧状态。
- VISA 通信失败后将当前会话标为失效，不重试普通命令；仅允许尽力发送 OFF，且不会把失效流中的数据当作关断确认。需要新建会话重新连接。
- 同一项目的脚本通过 `.lab_locks/utg932.lock` 互斥，进程退出由系统释放锁。厂商上位机不遵守此锁，实际使用时应关闭其他控制软件。
- 参数回读不等于真实电压测量；USB 掉线、程序被强制终止时软件无法保证关断。通道意外开启或 OFF 未确认时应使用面板关闭。

脚本采用保守范围：正弦 ≤30 MHz、方波/脉冲 ≤1 MHz、斜坡 ≤100 kHz，ARB 整表重复频率 ≤1 MHz；最低频率 1 μHz，幅值 2 mVpp～5 Vpp，开路电压极值限制 ±5 V，占空比/对称度 1%～99%。多音生成器单个音调限 500 kHz，适合本项目 ADC 测试。这是本项目自动化范围，未覆盖全部仪器规格；高频幅值、脉冲边沿等组合若被设备限幅，回读不符即失败。任意表含有的高次谐波/跳变不因重复频率合规就自动满足模拟带宽要求。

`HIGHZ` 对应该手册中的 LOAD=10000；`50` 对应 LOAD=50。负载参数用于幅值显示补偿，不会把输出源阻抗实际变为高阻。选 50 Ω 却接高阻负载时，电压可能接近显示值的两倍；脚本按此计算开路电压范围，仍须核对电路实际输入限值。

上传时可能影响两路波形选择，因此先关闭两路，传完后恢复上传前的波形选择并检查频率、幅值、偏置等是否变化；不自动恢复 ON。传输完成只证明文件已写出，设备没有提供本脚本可用的采样表 CRC/逐点回读；本次另用槽位/来源回读和屏幕确认加载结果。本版尚未包含调制及内置扫描。

下载原始屏幕 BMP（只读）：

```powershell
.\scripts\utg932.ps1 screen --save test_results/utg932_screen.bmp
```

本机原始 BMP 是水平镜像，直接保留固件返回原文，未自动改色或转向。实测归档中的 `*_readable.bmp` 只反转了水平像素顺序，供人工核对。面板预览不等于端口实测。

## 首次输出前的验证

本机身份、双通道 OFF 配置、自定义表上传与预览已经完成。实际连接被测电路前，仍需用示波器核对负载、倍率和输入范围，显式 ON 后测量实际幅值/偏置与多音频谱，再 OFF 并记录确认。未完成这一步不能称为电压校准或 FPGA 多音实测。

离线测试：

```powershell
.\.venv-hds\Scripts\python.exe scripts/instruments/test_utg932.py
```

33 项离线测试覆盖只读、单位标注、通道独立、波形参数、回读不符、配置意外 ON、USB 超时、短写、显式开关、范围拒绝、命令注入、型号/资源筛选、互斥锁、dry-run、日志防覆盖、EOM 读取、BSV 编解码/短上传、双路上传副作用检查、多音频率/幅比/混叠、JSON 参数读取和 DC 固件行为。离线测试不替代实机验证。

本机实测原始记录位于 `test_results/utg932_*.json`：`status_20261023_02` 为初始状态，`upload_20261023_03` 为上传，`arb_config_20261023_04` 为选波回读，`screen_20261023_05` 为屏幕下载，`arb_combined_20261023_06` 为整合命令，`profiles_20261023_07` 为四种预置成功及 DC 频率回读差异，`dc_20261023_08` 为修正后的 DC 复测与最终恢复。首次超时记录也保留，没有覆盖。

依据：[UNI-T 官方 UTG900E 编程手册](https://events.uni-trend.com/hubfs/Instrument%20Product%20documentation/Waveform%20Generators/UTG900E/UTG900E%20Programming%20Manual%20V1.0.pdf)、[官方产品页](https://instruments.uni-trend.com/UTG900E)。实际 VID/PID 来自本机 USB 枚举，未照搬手册中的示例资源。
