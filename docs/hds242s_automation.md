# HDS242S + Basys 3 自动化联调

## 当前实际验证状态（2026-10-15）

本机已通过官方 libusb-win32 驱动成功连接 HDS242S，真实固件为 V8.1.0；无需改装 Zadig/WinUSB，也无需安装 NI-VISA。使用 Python 3.12 64-bit、PyUSB 1.3.1 和 `C:/Windows/System32/libusb0.dll`。USB VID/PID 为 5345:1234，Bulk OUT/IN 为 01/81。

已验证：型号查询、发生器设置查询、屏幕波形 JSON 元数据、双通道屏幕字节流、Vpp/频率/平均值查询，以及输出保持 OFF 时的频率/幅值设置与恢复。尚未验证：实际输出电压、负载模式含义、带信号波形换算、FPGA JTAG/ILA 联机抓取、整个扫频闭环。此次没有开启发生器输出。

软件验证：8 项离线测试通过，覆盖 USB 跨块封包、错误会话终止、实际固件单位换算、计划数值限制、ILA CSV radix/有效事件解析和设置回读不符时禁止启用输出。Tcl 脚本已通过语法完整性检查并核对 Vivado 本地命令文档；尚未在连接 FPGA 的情况下运行。

初始仪器设置为 SINE、1 kHz、1 Vpp、0 V 偏置、OUT OFF；设置测试完成后已恢复。当前 CH1 开启、CH2 关闭，AC 耦合；用户接线后需配置通道。无输入情况下的波形与测量只用于验证通信，不能当作仪器精度、噪声或电路测量结果。

### 固件单位差异

协议中的参数单位不能直接套用该固件的查询返回值。本次通过面板读数和 OUT OFF 设置测试确认：

| 参数 | 设置命令单位 | 本机 V8.1.0 查询原值 | 解释 |
| --- | --- | --- | --- |
| 频率 | Hz | 1 kHz 返回 1e9；100 kHz 返回 1e11 | 查询值除以 1e6 得 Hz |
| 幅值 | Vpp | 1 Vpp 返回 1000；0.1 Vpp 返回 100 | 查询值除以 1000 得 Vpp |
| 偏置 | 非零设置尚未验证 | 设置 0.01 后仍返回 0；已恢复 0 | 脚本只允许零偏置，拒绝猜测非零单位 |

脚本对其他固件不猜单位，禁止直接扫频。`:FUNCtion:LOAD OFF` 按预期高阻模式编写，但仍须在面板与实测输出上核对模式含义与幅值，未核对前不运行实际扫频。

## 自动化范围与接线

```text
电脑 Python ─USB SCPI→ HDS242S OUT → 模拟滤波器 → ADC → FPGA
                         │              │                 │
                        CH1            CH2             JTAG/ILA
                         └────参考值─────┘                 │
电脑测试目录 ← 示波器波形/读数 + FPGA结果CSV/JSON ← Vivado Tcl
```

CH1 测滤波器输入，CH2 测 ADC 模块模拟输入连接器处。探头地接电路信号地，不接负电源；探头实际倍率和仪器倍率保持一致。建议 DC 耦合，以同时观察偏置与削顶。ADC 内部共模由模块前端处理，不应因发生器设置 0 V 偏置就假定 ADC 芯片引脚也为 0 V。

Basys 3 USB/JTAG 需另接电脑并已下载匹配 bit；现有 ILA 可回读 Vpp_raw、Vrms_raw、amp_raw、peak_bin 和结果事件。当前 ILA 没有原始 ADC/FIR 波形探针，不能通过现有探针下载整帧 ADC 数据；需要时另行修改探针并重新实现。当前脚本不修改 RTL，不下载新 bit。

厂家上位机与脚本可能争用 USB，请在正式采集前关闭厂家上位机。Vivado GUI 也不要同时占用同一 ILA 采集。

## 文件与环境

- `scripts/instruments/hds242s.py`：识别、示波器留档、扫频、可选 ILA 采集。
- `scripts/instruments/sweep_example.json`：10～500 kHz、100 mVpp、零偏置示例计划，默认禁止执行。
- `scripts/capture_hw_ila.tcl`：已有 FPGA 配置下，等待新 measurement_valid 后导出 CSV，15 秒超时。
- `scripts/instruments/test_hds242s.py`：不访问硬件的封包、单位、限幅与 ILA CSV 解析测试。

在工程根目录的 PowerShell 执行（本机环境已创建）：

```powershell
python -m venv .venv-hds
.\.venv-hds\Scripts\python.exe -m pip install -r scripts/instruments/requirements.txt
.\.venv-hds\Scripts\python.exe scripts/instruments/test_hds242s.py
```

虚拟环境、采集结果在 `.gitignore` 中，保存在本机。每次运行产生独立目录 `test_results/年月日_时分秒_微秒/`；指定 `--output` 时目标目录必须不存在，防止覆盖之前记录。

## 第一次实测顺序

1. OUT 关闭时接线，确认输入允许范围。示例计划为 100 mVpp、0 V 偏置，不能据 ±5 V 供电直接确定输入范围。
2. 示波器 CH1/CH2 开启，设置合适倍率、DC 耦合、量程、时基及触发。初次使用 100 kHz 正弦；让屏幕能看到数个周期和无削顶波形。
3. 单点核对实际输出与两通道读数，再运行扫频。脚本只检查通道开启，不会替用户自动选择正确探头倍率、量程或时基。
4. 启动 Vivado Hardware Manager/hw_server，确认 FPGA 已下载正确 bit/ltx 并能抓到 measurement_valid。单独验证 Tcl 后再启用闭环扫频。

单独读取 FPGA（不连接示波器，不改变发生器）：

```powershell
.\.venv-hds\Scripts\python.exe scripts/instruments/hds242s.py ila --vivado C:/AMDDesignTools/2025.2/Vivado/bin/vivado.bat --ltx G_FPGA.runs/impl_1/G_FPGA_Top.ltx
```

只查询型号和当前设置，不改变输出：

```powershell
.\.venv-hds\Scripts\python.exe scripts/instruments/hds242s.py identify
```

只读当前示波器状态，不改变通道和输出：

```powershell
.\.venv-hds\Scripts\python.exe scripts/instruments/hds242s.py capture --channels 1 2
```

生成扫频计划预览，不连接硬件：

```powershell
.\.venv-hds\Scripts\python.exe scripts/instruments/hds242s.py sweep scripts/instruments/sweep_example.json
```

核对接线、幅值、`limits` 和负载设置后，将计划中 `connections_confirmed` 改为 true，才可执行：

```powershell
.\.venv-hds\Scripts\python.exe scripts/instruments/hds242s.py sweep scripts/instruments/sweep_example.json --execute
```

`max_vpp` 限制发生器设定幅值；`min_output_v/max_output_v` 限制其电压极值，不能自动保证滤波器放大后的 ADC 输入不过载。脚本先关闭输出，设置正弦和参数，再查询核对；每个频点关闭输出后改参数、核对、启用、等待至少 1 秒，然后采集。完成或异常时发送 OFF；若通信故障不能确认关闭，终端提示手动关闭 OUT。程序崩溃、USB 掉线或断电情况下，软件不保证输出关闭。

加入 FPGA 采集（需已运行 localhost:3121 的 hw_server、单个 JTAG 目标和匹配探针）：

```powershell
.\.venv-hds\Scripts\python.exe scripts/instruments/hds242s.py sweep scripts/instruments/sweep_example.json --execute --vivado C:/AMDDesignTools/2025.2/Vivado/bin/vivado.bat --ltx G_FPGA.runs/impl_1/G_FPGA_Top.ltx
```

该模式每点启动一次 Vivado，速度较慢，适合首次联调。等待的是重新武装后的结果事件，不复用上一次 ILA 截图。示波器与 ILA 属于稳定信号的先后采集，没有硬件同步触发，不宣称逐采样点同步。若要无人值守长时间运行，应先完成单点及连续帧实测，再考虑常驻 Vivado 会话。

## 结果与分析边界

| 文件 | 内容 |
| --- | --- |
| session.json | 型号、开始/结束时间、成功/失败、输出关闭确认 |
| scpi_log.json | 每条命令及原始返回，追溯单位和协议问题 |
| point_NNN/scope.json | 示波器设置元数据、两通道原始波形字节和测量字符串 |
| point_NNN/ila.csv | Vivado 原始 ILA 采集，包含 radix 行 |
| point_NNN/fpga.json | measurement_valid=1 时的 FPGA 数值，频率由 bin×500 计算 |
| index.csv | 各点输入设置、文件索引、FPGA频率/误差、幅值 raw |

HDS242S 当前返回每通道 600 字节屏幕波形；保留原始 hex，不冒充 4K/8K 完整 ADC 记录，也不未经验证换算成电压或精密 RMS。`:MEASurement` 返回形如 `Vpp=1.200V`、`F=  ?`、`Vpp=OFF` 的字符串；未知/关闭不是 0。当前逐点报告保留这些原文，幅值自动拟合需先确认参考波形、有效读数和量程。

ILA Vpp 只含低 16 位，amp 只含低 31 位，与屏幕完整接口可能有截断差异。当前 FFT 峰值法为 500 Hz bin，频率误差不能按高分辨率频率计标准验收。现有幅值仍为 raw，尚不能宣称 ≤5 mV；使用 HDS242S 作为精度参考时，还应考虑其量程、8-bit 示波分辨率与实际校准不确定度。

运行结束后提供结果目录即可回读分析。对异常优先比较：发生器设置回读、CH1/CH2 实际波形/读数、FPGA原始结果；模拟链路的单独验证不能替代集成时的实际输入确认。

## 已有工具与资料

- 官方产品页与 SCPI 协议下载：https://www.owon.com.hk/products_owon_hds200_series_digital_oscilloscope
- 官方协议：https://files.owon.com.cn/software/Application/HDS200_Series_SCPI_Protocol.pdf
- 开源 USB/SCPI 工具：https://github.com/linux4life798/owon-hds200-capture （作者测试型号为 HDS272S，不能直接代替本机验证）
- HDS242 图形查看工具：https://github.com/sichardtg/osci-SCPI （启动说明要求 USB HID 模式，适合参考，不建议为它更换本机已工作的驱动）

本工程脚本独立实现，不内置上述项目源码。通信使用末尾 LF；波形命令返回 4 字节 little-endian 长度前缀。当前实现处理跨 USB 读块的封包，协议出错后终止会话，避免将上一条残留响应误标为下一项数据。
