# 用 Tektronix AFG1022 产生 G 题验收波形

研究日期：2026-10-30；基于拉取后的 `f56cb08` 验收规程、8 份向量和官方手册。

**建议使用 CH1 任意波形（ARB），把基波、谐波及 C 模式干扰在电脑上相加后上传。** A/B 两到三个分量、相位差，以及选定频率的 C 干扰均可放进一张表。CH2 保持 OFF，不需要外部合路器。本文提供的是制表及待执行操作方案；本轮没有连接仪器、上传 EMEM 或开启输出。

## 1. 能力与实现依据

| 项目 | 官方资料确认 | 对本项目的意义 |
| --- | --- | --- |
| AFG1022 ARB | 2～8192 点、14 bit、125 MS/s，重复频率最高 10 MHz | 现有 1000 点 A/B 表足够；不必用满 8192 点 |
| 输出阻抗 | 典型 50 Ω；负载菜单按选择的阻抗调整幅度显示 | HIGHZ 不会去掉内部 50 Ω，必须区分设置值与输入节点电压 |
| 编辑内存 | `DATA:DATA EMEMory,<binary_block_data>`；可整表查询 | 现有脚本已实现上传及全 DAC 码回读比较 |
| 波形选择 | `SOURce1:FUNCtion EMEMory` | 上传后选择易失编辑内存并设置连续输出 |
| 相位 | 官方通道相位命令要求 FreqLock | 表内直接写各谐波相位，无需通道联动 |

依据：[官方数据表](https://www.tek.com.cn/datasheet/arbitrary-function-generator)的任意波形/幅度/输出章节、[AFG1022 编程手册](https://download.tek.com/manual/AFG1022-Programmer-Manual-EN.pdf)印刷页 21～26、29～31，以及[快速用户手册](https://download.tek.com/manual/AFG1022-Quick-Start-User-Manual-EN.pdf)印刷页 29～31、48。

这里选择 ARB 是根据上述能力作出的工程方案。方波含额外高次谐波，不用于替代题目指定的基波加一/两个谐波。AM 也不能直接替代任意指定的谐波频率、幅度和相位。

## 2. 先统一电压与负载约定

设各分量峰值为 `Ui`，整表重复频率 `fr`，谐波阶数 `hi`，脚本参数 `--vpp S` 为归一化满量程：

```text
u(t) = Σ Ui sin(2π hi fr t + φi)
x[n] = Σ (2 Ui / S) sin(2π hi n/N + φi), n = 0..N-1
理想电压 = S/2 × x[n] + offset
整表输出频率 --hz = fr；分量频率 = hi × fr
```

不重复保存周期末尾的起点。各分量 `tones[].vpp=2Ui`，单位 V；屏幕幅值目标是 `Ui`，单位 mV。组合波 Vpp 要求极值差，RMS 为 `sqrt(ΣUi²/2)`，不能把每根谱线的 Vpp 相加当作组合波 Vpp。

### HIGHZ 与 50 Ω 实际负载

对 50 Ω 内阻的源，理想电阻模型下：

```text
输入节点电压 = 开路电压 × Rload / (50 + Rload)
```

已有验收规程指出前端输入约 50 Ω。若属实，HIGHZ 设置 100 mVpp 正弦，在该输入节点约为 50 mVpp；设置为 50 Ω 显示、100 mVpp，则源的开路电压约 200 mVpp，带 50 Ω 后约 100 mVpp。高阻探头并接现有 50 Ω 输入与把电缆改插示波器 1 MΩ，负载不同。

本项目现有默认校准 bank 和已有向量使用 **HIGHZ 设置值参考**。以下命令保留该约定，便于复现历史记录；生成文件的 `*_reference` 是这一约定下的数学值，不能直接认定为实际 BNC 电压。原题说明 7 使用源参数设置值作为标称值，正式记录仍须明确负载显示约定。

如果验收要求在装置 BNC 端实际达到这些电压，应在实际接线下测量，并使用匹配负载的设置：例如对确认的 50 Ω 输入，将下面上传与 ON 命令**都**改为 `--load 50`，保留同一个 S；或保留 HIGHZ，将 S 乘 2。此时已有 HIGHZ 参考校准 bank 不能直接沿用为绝对电压校准。C 的 200 mVpp 干扰也必须按选定约定核对，不能把带载后的 100 mVpp 当作实际 200 mVpp 干扰。

### 首次 ARB 必须做的幅度映射核验

现有驱动将 [-1,+1] 映射到 [0,16383]，按满量程解释幅度；**本机历史记录没有完成实机 ARB 上传及模拟端口核验**。所查手册没有充分说明本机固件对未用满 DAC 码范围的表是否再归一化，因此该映射仍需实测确认：

1. 在同一负载下比较内置正弦与 ARB 正弦，频率取 100 kHz。
2. ARB 满量程设 200 mVpp，分别上传 `sin(θ)` 和 `0.5sin(θ)`；保持幅度设置相同。理想比例应为 2:1。
3. 若两张表都产生相同 Vpp，或比例/直流位置不符，暂停使用本文绝对幅度参考，先修正驱动对该固件的映射。
4. 同时核对量化码回读、频率、零偏置、相位关系、插值及失真。回读成功只证明传输一致，不能证明模拟输出正确。

## 3. A/B 配方与首个可执行例子

所有表均为 1000 点、0 V 偏置；表中 Ui 为各分量**峰值 mV**，S 是脚本满量程 Vpp，非合成波总 Vpp。

| 向量 | `--hz` Hz | 成分 kHz | Ui mV | 相位° | `--vpp S` V | 目标总 Vpp / RMS mV |
| --- | --- | --- | --- | --- | --- | --- |
| A_TWO | 50000 | 50,150 | 60,25 | 0,0 | 0.17 | 120.748 / 45.962 |
| A_THREE | 10500 | 10.5,31.5,42 | 60,25,15 | 0,0,0 | 0.20 | 137.041 / 47.170 |
| A_HIGH | 50000 | 50,150,200 | 60,25,15 | 0,0,0 | 0.20 | 137.041 / 47.170 |
| B_LOW | 10000 | 10,30,40 | 30,12.5,7.5 | 0,0,0 | 0.10 | 68.521 / 23.585 |
| B_HIGH | 125000 | 125,375,500 | 30,12.5,7.5 | 0,0,0 | 0.10 | 68.521 / 23.585 |
| B_WEAK | 125000 | 125,375,500 | 5,25,20 | 0,90,0 | 0.10 | 87.755 / 22.913 |
| B_PHASE | 125000 | 125,375,500 | 30,12.5,7.5 | 0,90,0 | 0.10 | 78.767 / 23.585 |
| B_OFFGRID | 124750 | 124.75,374.25,499 | 30,12.5,7.5 | 0,0,0 | 0.10 | 68.521 / 23.585 |

先在仓库根目录离线生成文件；此步骤只需要 Python 标准库，不需要 VISA：

```powershell
New-Item -ItemType Directory -Force test_results/afg_acceptance | Out-Null
python scripts/instruments/afg1022_acceptance.py docs/acceptance_vectors/A_THREE.json --save test_results/afg_acceptance/A_THREE.json
.\scripts\afg1022.ps1 arb test_results/afg_acceptance/A_THREE.json --channel 1 --hz 10500 --vpp 0.2 --offset-v 0 --load HIGHZ --dry-run
```

确认第 2 节的负载及映射后，执行上传和输出。以下命令**没有在本轮执行**；上传覆盖两路共享的易失 EMEM，上传结束两路 OFF：

```powershell
.\scripts\afg1022.ps1 arb test_results/afg_acceptance/A_THREE.json --channel 1 --hz 10500 --vpp 0.2 --offset-v 0 --load HIGHZ
.\scripts\afg1022.ps1 status --channel 1
# 核对上传全码匹配、无错误、CH2 OFF，然后开启：
.\scripts\afg1022.ps1 output on --channel 1 --waveform arb --hz 10500 --vpp 0.2 --offset-v 0 --load HIGHZ
# 测完关闭：
.\scripts\afg1022.ps1 output off --channel 1
.\scripts\afg1022.ps1 output off --channel 2
```

AFG 的 `output on` 会重新配置，不能省略 `--waveform arb` 和频率/幅度；也不能直接把计划 JSON 当作采样表上传。新制表工具不覆盖已有目标文件；换文件名或先核对旧文件。

其他 7 组更换计划路径，并按上表填写频率和 S。幅值边界 A=100/250 mVpp、B=50/250 mVpp，可保持样本不变，把 S 统一乘以 `目标总Vpp / 表中原总Vpp`，使用生成文件中完整精度的 `signal_reference.vpp_v` 计算；各 Ui 和 RMS 同比例变化，记录新标称值。边界处应核对实际幅度量化和测量不确定度。

## 4. C 模式：一张表叠加干扰

用 B_HIGH 作 ub，选择 fJ=1 MHz，Ui=30/12.5/7.5 mV；干扰峰值 100 mV（200 mVpp）：

```text
θ = 2π×125000t
u = 30sinθ + 12.5sin3θ + 7.5sin4θ + 100sin8θ  [mV]
x = u/150；满量程 S = 300 mVpp；整表重复频率 125 kHz
```

300 mVpp 是满量程。ub 仍为 68.520527 mVpp / 23.584953 mVrms，频谱峰值仍为 30/12.5/7.5 mV；总输入波形另有 1 MHz、100 mV 峰值。C 的显示应与 ub 比较，不能与混合信号的 Vpp/RMS 比较。

制表工具生成相同 300 mVpp 满量程下的三个文件，便于分别检查源：

```powershell
python scripts/instruments/afg1022_acceptance.py docs/acceptance_vectors/B_HIGH.json --interference-hz 1000000 --part signal --save test_results/afg_acceptance/C_ub.json
python scripts/instruments/afg1022_acceptance.py docs/acceptance_vectors/B_HIGH.json --interference-hz 1000000 --part interference --save test_results/afg_acceptance/C_J.json
python scripts/instruments/afg1022_acceptance.py docs/acceptance_vectors/B_HIGH.json --interference-hz 1000000 --part mixed --save test_results/afg_acceptance/C_mix.json
.\scripts\afg1022.ps1 arb test_results/afg_acceptance/C_mix.json --channel 1 --hz 125000 --vpp 0.3 --offset-v 0 --load HIGHZ --dry-run
```

实际执行时，每张表均先 OFF→上传→核对→ON。三张表使用完全相同的 `--hz 125000 --vpp 0.3 --offset-v 0 --load HIGHZ`；开启仍须完整 `output on --channel 1 --waveform arb ...`。不要对 C_ub 改回 0.1，也不要对 C_J 改成 0.2，否则会再次缩小分量。按第 2 节选择的实际负载约定统一调整三张表的参数。

建议依次用 1、2、4 MHz；B_HIGH 的对应阶数是 8、16、32，1000 点表分别约有 125、62.5、31.25 点/干扰周期。`N×fr=125 MS/s` 是表的等效采样率；不据此推断所有设置下仪器内部 DAC/插值的具体运行方式。4 MHz 对约 4.096045 MSPS 的 ADC 会折叠到约 96.045 kHz，有助于检查模拟抗混叠滤波，不能仅靠数字低通处理。

工具要求干扰与原表重复频率成整数比，并至少有 8 个表点/干扰周期，这是本工具的制表约束。例如不能直接将 1 MHz 加入 A_THREE 的 10.5 kHz 整周期表。若改用共同周期，10.5 kHz 与 1 MHz 的最大公约频率为 500 Hz，干扰阶数 2000；即使用满 8192 点也只有约 4.096 点/干扰周期，不宜直接套用现有精度结论。

遇到指定的非整比 fJ，应重新设计共同周期与点数，或使用 CH1=ub ARB、CH2=干扰正弦配合**合适的合路网络**，核对插损与每个分量的节点电压。不能用 BNC T 直接并联两路低阻输出。本工具的 1～10 MHz 研究范围和选定三点不代表原题所有 fJ≥1 MHz 已覆盖，也不代表均已实测通过。

## 5. 本轮完成与上机顺序

本轮离线完成：

- 新工具 `scripts/instruments/afg1022_acceptance.py`，复用已有 A/B 合成器；保持各分量幅度和相位，不引入自动归一化；支持 C 的三种分离表。
- 原有 AFG 驱动 6 项测试及新增 3 项测试通过。新增测试覆盖全部 8 组 A/B、C 的 1/2/4 MHz 三频与三个 part；用独立 DFT 检查 14-bit 量化后的各峰幅，误差限 2 µV，以及非整比/采样不足/非法频率拒绝。
- 本机 `test_results/afg1022_acceptance_20261030/` 已生成 8 份 A/B、9 份 C 采样表和 `summary.json`；该目录按项目规则不入 Git，可用工具重新生成。
- 当前系统 Python 未安装 PyVISA，项目 `.venv-hds` 也不存在。离线生成、dry-run 和模拟测试可运行；实际通信需在有 PyVISA 与可用 VISA 后端的仪器控制环境中执行，见[已有驱动说明](afg1022_automation.md)。没有据此更换驱动或安装依赖。

上机顺序：先做 ARB 满/半幅映射和实际负载核验，再做 A_THREE，之后 B_HIGH/B_PHASE/B_WEAK/B_OFFGRID，再做 C_ub、C_J、C_mix。每组按[验收规程](contest_acceptance_runbook.md)取新帧、展示 1T/3T、核对峰值与 RMS，并记录屏幕四项完成时间。AFG 传输/配置成功与 FPGA 验收通过分开记录。

```powershell
python -m unittest discover -s scripts/instruments -p 'test_afg1022*.py'
```
