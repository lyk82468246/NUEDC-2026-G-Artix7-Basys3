# ILA超时诊断扩展（2026-10-23）

目的：针对P3实板“完成事件停止、LD7/LD12亮、UART空闲”故障，增加只读观测。不是通过自动复位、延长超时或提高噪声门限来隐藏故障。首版P3六探针bit和现场CSV已备份；诊断版的构建/下载结果必须另记，不能沿用旧bit/LTX散列。

后续用户确认先前ADC曾掉电，现已恢复；停止针对该次超时的RTL排查。诊断探针保留作可选观测，不代表已定位RTL缺陷。此后改为用户手动综合/实现/生成bit/烧写，具体交接和历史十探针构建散列见[手动构建说明](manual_vivado_workflow.md)。

用户已确认ADC及滤波器仍供电。异常码1只说明发生过超时，不能由它单独推断当前一定在RUN或FAULT；可能仍在等待过零触发，须看新增run_state和ADC原始码。故障原始取证及数值见[P3记录](p3_signal_validity_20261023.md)。

## 探针

探针0～5保持原位宽和名称：measurement_valid、Vpp16、RMS16、谱幅31、bin12、UART状态5。

| 探针 | 名称 / 位宽 | 作用 |
| --- | --- | --- |
| 6 | diagnostic_status / 32 | 控制器、忙标志及阶段事件锁存 |
| 7 | diagnostic_adc / 12 | 已同步至100MHz域的ADC原始码，不是滤波波形 |
| 8 | diagnostic_bins / 36 | 三个候选频率bin，低12位为第一个；无效信号仍保留诊断候选 |
| 9 | diagnostic_noise / 32 | 候选主瓣排除后的谱幅背景均值raw |

所有探针时钟100MHz，深度1024。ADC样本只约每24～25拍更新，因此1024拍只覆盖约42个ADC样本，不等于1024个独立ADC点。

## 状态字

| 位 | 含义 |
| --- | --- |
| 31:28 | error_code，1=事务超时、2=采集期间原始ADC碰轨 |
| 27:25 | run_state：0 IDLE、1 ARMED、2 RUN、3 DRAIN、4 FAULT |
| 24:20 | 去抖开关 {SW15,SW3,SW2,SW1,SW0} |
| 19 / 18 / 17 | capture_enable / controller_release / capture_start |
| 16 / 15 / 14 / 13 | 当前拍frame_valid / time_result_valid / fft_result_valid / peak_result_valid |
| 12 | 当前HMI快照的信号有效标志 |
| 11 / 10 / 9 / 8 / 7 | capture / time_calc / FFT / peak / HMI busy |
| 6 / 5 | packet_finished / acquisition_fault |
| 4:0 | 本事务曾出现 frame / time / FFT / peak / measurement 完成事件 |

事件位在capture_start清零，然后置位保持；控制器处于ARMED重试或FAULT时不自动清除，因此能看到故障前完成到哪一级。复位或重新下载会丢失现场，应先即时抓取。事件位不包含先后顺序，也不是完整事务历史；若需时序，仍应选择相应事件触发并调整触发位置。

## 使用

正常验收仍触发measurement_valid；超时诊断使用现有`capture_hw_ila.tcl`的第三参数`immediate`，不等待完成事件，不重新下载。使用与当前bit匹配的LTX，CSV必须新文件，避免旧数据混入。

```powershell
.\.venv-hds\Scripts\python.exe scripts/instruments/inspect_ila.py <新抓取的CSV路径>
```

解码器只读CSV、不会操控硬件。`completed_packet_samples=0`表示该窗口没有完成事件，Vpp/RMS等只是保留寄存器，不能据此报告新的测量或用于标定。候选bin、ADC极值、背景均值需结合有效性和模拟链路共同判断，不能因出现188kHz就硬编码陷波排除。

## 构建注意

`setup_board_top.tcl`已配置十探针；Vivado 2025.2中Clocking Wizard的`CLKOUT*_DRIVES`在已有IP上只读，脚本改为校验BUFG而不是重复写入。当前诊断构建专门只更新ILA，未重新配置时钟。工程原有Basys3 board-store路径缺失告警仍存在，器件part和显式XDC是当前构建依据，不据此宣称板级定义完整。

仅`generate_target`不能保证旧OOC检查点被重新综合：本轮曾生成十探针wrapper却仍引用六探针DCP，顶层因此报告probe6～9不存在。现有十探针DCP已重新生成；GUI手动流程中，若日后修改IP，应由用户通过Generate Output Products及相应IP综合更新检查点。`scripts/refresh_ila_checkpoint.tcl`保留为独立batch历史工具（参数为ILA XCI路径，第二参数`check`仅校验配置），助手不再自行执行其完整重建。脚本使用AMD规定的非工程`read_ip`/`synth_ip`流程，避免在已打开工程中调用`synth_ip`的模式告警。参见[AMD UG896非工程综合示例](https://docs.amd.com/r/2025.1-English/ug896-vivado-ip/Scripting-Examples)。

本轮该脚本`check`模式已在Vivado 2025.2通过；完整ILA检查点由本轮构建封装中的强制OOC综合实际生成（调用时产生工程模式告警，但后续IP综合完成且DCP已更新），不把只读检查模式冒充完整重建测试。离线回归：37项仪器/解码测试、11项参考模型测试通过。
