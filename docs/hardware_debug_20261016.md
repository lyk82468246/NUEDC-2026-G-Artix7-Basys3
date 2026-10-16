# 2026-10-16 自动化实板联调记录

连接：HDS242S OUT → 模拟滤波器 → AD9226 → Basys 3；USB/JTAG 读取 ILA。CH1/CH2 未并联测量。屏幕尚未完成调试，本记录不验收显示与实际输入端电压精度。

## 仪器与工具适配

- HDS242S V8.1.0：频率查询以 µHz 返回、幅值查询以 mV 返回，已转换到 Hz/Vpp；本次只使用零偏置。
- 现场核对面板：100 kHz、0.1 Vpp、高阻。LOAD ON 对应高阻，LOAD OFF 对应 50 Ω，修正旧脚本错误假设。参数设置后逐项确认 OUT OFF，不重复发 FUNCtion SINE 初始化。
- Vivado 2025.2 批处理需 PROCESSOR_ARCHITECTURE=AMD64、XILINX_LOCAL_USER_DATA=NO 及运行库 PATH；采用 SUBST 别名避免本机 Documents 路径归一化异常。别名只复用相同目录映射或临时创建空闲盘符。
- 本机没有 stop_hw_ila 命令。基本型 ILA 的部分 CONTROL 属性只读；reset_hw_ila 后读取核验默认值，避免写只读项。
- wait_on_hw_ila 的 timeout 单位是分钟。超时可能正常返回并导出仅两行表头的 CSV；当前导出脚本显式拒绝无样本文件。立即触发快照只作诊断，不作为新 measurement_valid 结果。

## 修正前观察

100 kHz、100 mVpp、高阻、零偏置下，多次等待 15 秒未得到新结果事件。重新下载本地既有 bit 后，成功抓到一笔新事件：

| 条件 | peak_bin | FPGA Hz | Vpp_raw | Vrms_raw | amp_raw |
| --- | --- | --- | --- | --- | --- |
| 修正前，100 kHz | 200 | 100000 | 1795 | 1099 | 781909 |

证据：[修正前原始 ILA CSV](../reports/hardware_20261016/before_dc_fix_100k.csv)；本机原目录为 `test_results/lab_2026-10-16T09-50-28.419+08-00_3a587c/927c106df0a346eda5a2bceb2a106059/ila.csv`。后续相同输入的连续切频计划再次超时，不能据这一笔成功宣称稳定刷新。

修正前实际下载 bit 的 SHA-256：`42BC92B5B12C8DBA11FE825C0025630B4FA3733C41C2F198BF8F2DED787EFF92`；LTX：`780E91292AEDC2DA7750032CA408AE2CF1DB3CC1F1E4D606DE7EA741B2BB101E`。

## 去直流量化问题与回归

原式 `dc_next = dc + ((x-dc) >>> 12)` 的状态只保留整数。正误差小于 4096 时修正为 0，而负误差趋向 -1。对小信号，估计值可落到负峰附近；一次更低的异常点后，未来样本全部大于估计值而不再触发过零。

硬件数据也符合这一机制：`1795 × sqrt(3/8) ≈ 1099`，相当于正弦整体上移至非负区间后的 RMS。该比例是诊断线索，不能替代模拟端独立参考测量。

新增 `tb_afe_small_signal.sv`，使用 FIR 一周期恒等模型，单独验证 AFE 符号运算、DC 跟踪、过零、帧冻结/释放及重新触发。输入为有符号 ±400 raw 的周期序列，稳定后插入一个 -416 raw 异常样本。

| RTL | 异常后的完成帧 | 输出均值/范围 | 结果 |
| --- | --- | --- | --- |
| 原版整数状态 | 0 | 无新帧 | 按预期复现失败 |
| 修订版 Q*.16 状态 | 77 | 均值约 0.5 raw LSB；-400～401 | PASS |

修订仅为 DC 估计累加器增加默认 16 位小数，保留时间常数、接口和采样率。误差减法及状态更新带符号扩展与额外保护位，输出仍为 signed 16-bit。该回归不覆盖真实 FIR 频响或 ADC 物理时序。

运行当前 RTL：`scripts/run_afe_capture_sim.ps1 -Tag fixed`；`Tag` 只决定日志目录，不切换 RTL 版本。原版失败日志在修改 RTL 前以 `-Tag baseline` 生成。仓库保留 [原版日志](../reports/hardware_20261016/afe_baseline.txt) 和 [修订日志](../reports/hardware_20261016/afe_fixed.txt)，完整临时目录为 `test_results/afe_capture_baseline/` 与 `test_results/afe_capture_fixed/`。

`scripts/run_behavioral_sim.ps1` 四组 XSim 回归均 PASS：时域 Vpp=16000 / Vrms=4898；FFT 8192 输入与 4096 写出；谱峰 index=123 / 61500 Hz；HMI 解码 184 UART 字节。Python 离线回归共 36 项 PASS。这些仿真不代替模拟输入参考测量。

## 重建与复测

### 实现与下载

2026-10-16 10:21 完成重新综合、实现及 bit/LTX 生成，随后通过 `setup_hw_session.tcl` 下载。配置状态 CRC_ERROR=0、PLL_LOCK_STATUS=1、DONE_PIN=1；识别到 `u_ila_system` 和全部六组探针。

| 项目 | 结果 |
| --- | --- |
| WNS / TNS | +0.082 ns / 0 ns |
| WHS / THS | +0.022 ns / 0 ns |
| LUT / FF | 9535 / 14299 |
| BRAM / DSP | 39/50 / 74/90 |
| DRC | 0 errors，13 warnings；并非零告警 |
| Routable nets | 21986/21986 全部布线，routing errors=0 |
| Bus skew | 4 项均 MET，最小裕量 +9.145 ns（debug hub 内部约束） |

新 bit SHA-256：`8CCB45050EB95B07642F00DF1588FEA0C3639378537B3A78C142A3D5DD2127C5`。新 LTX：`780E91292AEDC2DA7750032CA408AE2CF1DB3CC1F1E4D606DE7EA741B2BB101E`。探针布局未变，因此 LTX 散列与旧版相同，不代表没有重建。本次下载文件位于 `G_FPGA.runs/impl_1/`。

补充检查脚本 `scripts/check_routed_signoff.tcl` 输出仓库 `reports/board_top_{bus_skew,route_status,check_timing,cdc,methodology}.rpt`。`check_timing` 无无时钟寄存器、无内部未约束终点；按键输入缺少 input_delay，时钟转发/UART 输出缺少 output_delay。CDC 报告有 12 条 ADC bundled-data 数据路径 CDC-15 Warning；方法学报告仍提示同步时钟之间 false path 等事项。未用降低规则等级、添加豁免或虚构外部延迟来消除告警。现有外部时序假设及 CDC 结构仍需专门审查，功能板测不等于完整接口时序验收。

重建前工程文件及旧 bit/LTX 已备份到 `test_results/before_afe_dc_fix_20261016/`。构建引起的 XPR 序列化改动已恢复到构建前逐字节一致的备份（不是覆盖用户原有未提交设置）。

### 连续板测

第一组任务 `495b0c5bfffe485aa697c2a3fa886917`：100 mVpp、高阻、零偏置，100k→200k→50k→100k，每点两次。**8/8 新事件成功，全程未复位、未重新下载**。

| 顺序 / 设定 Hz | 两次 peak_bin | 两次 Vpp_raw | 两次 Vrms_raw | 两次 amp_raw |
| --- | --- | --- | --- | --- |
| 1 / 100000 | 200 / 200 | 1788 / 1793 | 626 / 626 | 781311 / 781211 |
| 2 / 200000 | 400 / 400 | 1774 / 1782 | 620 / 620 | 774252 / 774784 |
| 3 / 50000 | 100 / 100 | 1796 / 1790 | 627 / 627 | 783234 / 783310 |
| 4 / 100000 | 200 / 200 | 1791 / 1794 | 626 / 626 | 781431 / 781715 |

原始 CSV、逐点 JSON、计划及任务终态见 [continuous](../reports/hardware_20261016/continuous/)。所有记录 `simulated=false`，scope=null；采集等待的是重新武装后的 `measurement_valid=1`，不是立即触发旧快照。每次启动 Vivado 需约数十秒，所以这些时间戳不用于测量 FPGA 每秒帧数，也不宣称已经完成长时间运行验证。

同条件修复前后：Vpp 从 1795 到约 1790，幅值尺度基本不变；Vrms 从 1099 到 626；`1788/626≈2.856`，接近理想正弦的 `2√2≈2.828`。RMS 偏高及过零停滞的诊断得到同条件板测支持，但尚无参考示波器确认实际波形/电压，不能将约 1% 的比例偏差归因于某个单独器件，也不能据此宣称 mV 精度。

第二组任务 `d7c312d293ae4df28013ff299431744b`：补充范围与半幅测试 **7/7 成功**，原始记录见 [range](../reports/hardware_20261016/range/)。

| 设置 Hz | 设置 Vpp / V | peak_bin | Vpp_raw | Vrms_raw | amp_raw |
| --- | --- | --- | --- | --- | --- |
| 10000 | 0.1 | 20 | 1792 | 627 | 782371 |
| 20000 | 0.1 | 40 | 1794 | 627 | 782505 |
| 300000 | 0.1 | 600 | 1752 | 612 | 763553 |
| 400000 | 0.1 | 800 | 1724 | 600 | 748859 |
| 500000 | 0.1 | 1000 | 1678 | 585 | 730824 |
| 100000 | 0.05 | 200 | 902 | 313 | 391058 |
| 100000 | 0.1 | 200 | 1792 | 625 | 780446 |

本日修复后合计 **15/15 新事件成功**，覆盖 10/20/50/100/200/300/400/500 kHz 八个频点。两组之间也未复位或重新下载。全部 FPGA 名义 `index×500` 结果与发生器设置一致；这里“频差 0”只表示名义格点相同，不是独立测得真实频率误差为零。

100 kHz 半幅测试的 RMS 为 `313/626=0.500`，频谱幅值约为满幅的 0.500；Vpp 为约 0.504，包含峰值对噪声和取样的敏感性。仅证明这两个幅度设定下响应大致成比例，不代表整个动态范围线性度或绝对电压已标定。

### 后续仍需解决的测量问题

1. 同设定 100 mVpp 时，500 kHz 相对 100 kHz 的 RMS/FFT 幅值约下降 **6.5%**（585/626 与 730824/781431）。两种幅值一起下降，不能仅归因于 FFT 缩放。直接从当前 FIR XCI 的 95 个 Q1.15 系数计算 `|Σh[n]exp(-j2πfn/Fs)|`，名义 Fs=4.096 MHz 时，100 kHz 增益约 0.999977704，500 kHz 约 0.999938962；这部分理论系数频响不足以解释 6.5% 衰减。仍需独立参考区分发生器输出、模拟滤波器、ADC 模块及实际采样链路的贡献，暂不自动更改 `MAG_SCALE_FACTOR`。
2. 目前只能读取六组 ILA 结果探针，没有导出完整 ADC 时域波形；不能独立验收模拟端削顶、失真、噪声、ADC 位序/建立保持裕量。未完成非整 bin、干扰叠加、非零偏置或长时间运行测试。
3. 串口屏尚未调通，本轮未验收屏幕文字和曲线。现有 HMI 是单向 TX，不等待屏幕 ACK；屏幕状态不妨碍本轮 JTAG 结果读取，但也不能据结果事件断定屏幕显示正确。

### 结束状态与复现

两组计划各自自动执行 OFF；最终服务关闭时再次获得 OFF 确认，最后设置为 100 kHz / 0.1 Vpp / HIGHZ / 0 V。服务正常退出，`running=false`，无活动/排队任务。最终持久状态见 [shutdown_state.json](../reports/hardware_20261016/shutdown_state.json)。Basys 3 保持本次新 bit 运行；JTAG 是易失配置，断电后需重新下载。

完整本机日志目录：`test_results/lab_2026-10-16T10-23-12.448+08-00_d02410/`。仓库只归档逐点原始 ILA、JSON、计划和终态，不提交本地 API 令牌、bit/DCP、临时缓存或 USB 大日志。按 [服务指南](lab_api.md) 启动硬件服务并 connect，核对接线/限制后执行 `run_plan`，最后 shutdown；不要将归档的旧 CSV 当作新采集结果。
