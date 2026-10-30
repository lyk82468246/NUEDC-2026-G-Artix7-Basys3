# AFG1022 控制脚本

图形界面入口：`scripts/afg1022_gui.ps1`，支持赛题 A/B/C、自定义谐波、单频干扰和分离对照输出，见 [Tkinter 测试台说明](afg1022_gui.md)。

验收组合波的完整配方、HIGHZ/50 Ω换算、A/B/C制表与执行步骤见[AFG1022验收波形方案](afg1022_acceptance_waveforms.md)。新增制表入口仅离线运算，不连接仪器。

入口 `scripts/afg1022.ps1`，Python 类 `scripts/instruments/afg1022.py:AFG1022`。复用项目 `.venv-hds` 中的 PyVISA 和现有 NI-VISA；无需新增包、替换 USB 驱动。其他电脑依赖见 `scripts/instruments/requirements-utg932.txt`。

协议依据：[Tektronix AFG1022 编程手册](https://download.tek.com/manual/AFG1022-Programmer-Manual-EN.pdf)。仅自动发现 USB `0699:0353`，打开后核验厂商及型号；多台时用全局 `--resource` 参数选择。与其他仪器使用独立进程锁。

## 常用调用

在工程根目录运行（入口自身也支持从其他目录调用）：

```powershell
.\scripts\afg1022.ps1 diagnose
.\scripts\afg1022.ps1 identify
.\scripts\afg1022.ps1 status --channel 1
.\scripts\afg1022.ps1 status --channel 2
.\scripts\afg1022.ps1 configure --channel 1 --waveform sine --hz 100000 --vpp 0.1 --offset-v 0 --load HIGHZ --dry-run
.\scripts\afg1022.ps1 configure --channel 1 --waveform sine --hz 100000 --vpp 0.1 --offset-v 0 --load HIGHZ
.\scripts\afg1022.ps1 output on --channel 1 --waveform sine --hz 100000 --vpp 0.1 --offset-v 0 --load HIGHZ
.\scripts\afg1022.ps1 output off --channel 1
.\scripts\afg1022.ps1 output off --channel 2
```

`diagnose` 仅列资源；`identify/status` 只查询。查询会话关闭时不改变输出。`configure` 先关闭目标输出，配置后回读，保持 OFF。`output on` **重新按本命令参数配置**后开启，不沿用之前的面板/脚本设置；因此开启时应提供完整参数。默认值为正弦、1 kHz、100 mVpp、0 V、HIGHZ。失败返回非零退出码并尝试关闭两路；通信失败时 OFF 无法保证，须核对面板。JSON 输出可用于其他脚本。

支持 sine/square/pulse/ramp/dc/arb；方波、脉冲占空比和斜坡对称度沿用面板值，本版不提供其设置接口。CH1 配置会关闭调制、扫频和突发；两路频率联动都会关闭，避免频率写入影响另一通道。相位控制要求联动，本版未开放。DC 不写入/核对频率。

自动化范围为 2 mVpp～5 Vpp，开路峰值不超过 ±5 V；50 Ω 显示设置按开路电压翻倍核算。频率范围见脚本 `LIMITS`，其中部分波形采用保守上限，不代表硬件完整规格。负载参数影响显示及电压换算，不是切换物理输出电阻。`status.amplitude` 为仪器原始幅度读数，因固件不支持 `VOLT:UNIT?`，不自动标为 Vpp；配置显式发送 VPP 后核对数值。

## 任意波形

JSON 数组或 `{"samples": [...]}`；CSV/TXT 单列、无表头，可有 `#` 注释。2～8192 点，有限数值 [-1,1]，不自动归一化/削顶；映射为 14 位 DAC 码。

```powershell
.\scripts\afg1022.ps1 arb my_wave.json --channel 1 --hz 1000 --vpp 0.1 --dry-run
.\scripts\afg1022.ps1 arb my_wave.json --channel 1 --hz 1000 --vpp 0.1
.\scripts\afg1022.ps1 output on --channel 1 --waveform arb --hz 1000 --vpp 0.1
```

上传关闭两路，覆盖两通道共享的**易失编辑内存 EMEM**，不写 USER 非易失槽。使用大端无符号 16 位 IEEE 二进制块，并要求全表 DAC 码读回一致才成功。`hz` 为整表重复频率；JSON 中其他元数据不自动当作输出设置，须明确传参。±1 对应设定的满量程 Vpp，不满幅表格实际峰峰值相应减小。上传后只配置目标通道，保持两路 OFF；使用 EMEM 的另一通道也会受到表内容变化影响。

```python
import sys
sys.path.insert(0, 'scripts/instruments')
from afg1022 import AFG1022

with AFG1022() as afg:
    print(afg.settings(1))
    afg.configure_sine({'hz': 100000, 'vpp': 0.1, 'offset_v': 0}, channel=1)
    # afg.output_on(1, waveform='sine', hz=100000, vpp=0.1, offset_v=0)
    afg.output_off(1)
```

## 本机验证（2026-10-30）

资源 `USB0::0x0699::0x0353::1931263::INSTR`，身份 `TEKTRONIX,AFG1022,1931263,SCPI:99.0 FV:V1.2.4`。身份、两路状态和 CH1 配置回读已通过。最终 CH1 正弦 500 kHz、100 mVpp、1.5 V 偏置、HIGHZ、OFF；CH2 正弦 1 kHz、原始幅度 3.3、1.65 V 偏置、HIGHZ、OFF。未开启输出，未测量端口电压。任意波形协议通过模拟传输测试，未在实机覆盖已有编辑内存，暂不宣称硬件上传验收。

探测不支持的幅度单位查询产生了语法错误，已读取错误队列并在完整配置重测中确认无错误。脚本不使用该查询，不自动清空历史错误；存在历史错误时配置会失败并报告队列内容。

受限进程可能无法访问系统 VISA（本机出现 `VI_ERROR_SYSTEM_ERROR`）；允许系统运行库访问的进程中通信成功。不要据此判断需要重装驱动。本版为独立入口，尚未接入现有常驻 lab HTTP 服务。

回归：`.\.venv-hds\Scripts\python.exe -m unittest discover -s scripts/instruments -p 'test_afg1022.py'`。

## 谐波与噪声实机补充验证（2026-10-30）

已通过 tmp/afg_harmonic_noise.py 上传8192点并逐点读回匹配，随后开启CH1。修正二进制传输为大端；小端会导致DAC码越界及削顶。上传后等待0.3秒再查询，避免立即发送 *WAI 后出现空回复。HIGHZ幅度请求104.314 mVpp、回读104 mVpp，验证容差按实测1 mVpp量化步长调整。CH1整表625 Hz（表内16周期，对应10 kHz基波），EMEM、HIGHZ、0 V偏置、ON；CH2保持OFF。二次/三次谐波设定10%/5%，基波对噪声30 dB；端口实际幅度及频谱尚未测量。本条状态仅对应此次验证时刻。
