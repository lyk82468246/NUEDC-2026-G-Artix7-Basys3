# 当前ILA采集与故障排查

当前程序采用15探针、100MHz时钟、深度1024；schema3默认开启原始候选观测。匹配版本见[当前状态](project_status.md)，bit/LTX关联见[手动工作流](manual_vivado_workflow.md)。

## 捕获一个新结果

在GUI设置probe0（debug_measurement_valid）等于1并Run Trigger。显示中的旧capture不会自动更新，每次要重新arm。它是同帧结果事件，不是ADC帧完成信号。脚本入口只读取当前已烧写程序，不重新下载：

```powershell
# 先配置好Vivado运行环境；也可在GUI中捕获并导出CSV
.\.venv-hds\Scripts\python.exe -E scripts/instruments/inspect_ila.py test_results/new_capture.csv
```

自动捕获脚本是`scripts/capture_hw_ila.tcl`，参数为新CSV路径、匹配LTX、可选`immediate`。默认等待新measurement_valid，超时15秒；immediate用于停滞现场，但没有新事件的即时窗口不能用于标定。主机解码schema2/3原子快照要求恰好一个新事件。只保留一个JTAG操作者。

## 探针与schema3

| Probe | 位宽 | 含义 |
| --- | --- | --- |
| 0 | 1 | 同帧measurement_valid |
| 1 / 2 | 17 / 16 | Vpp raw / RMS raw |
| 3 / 4 | 32 / 12 | qualified基频幅值raw / 基频bin，无效时0 |
| 5 / 6 / 7 | 5 / 32 / 12 | 实时UART状态 / diagnostic_status / 同步ADC原始码 |
| 8 | 36 | 原始候选bin，低12bit为槽0 |
| 9 | 32 | 实时谱底均值raw |
| 10 / 11 | 96 / 2 | 原始候选幅值（每槽32bit、槽0在低位）/ 候选数 |
| 12 / 13 / 14 | 32 / 32 / 8 | 同帧编号 / 标定epoch / metadata |

metadata：bit0信号有效、bit1标定启用、bit2有VIO、bit4:3模式、bit5单次、bit6三周期、bit7原始候选schema3。schema2的bit7=0，候选槽按有效性清零；不能套用旧规则解释schema3无效帧仍保留候选。未使用槽为0，候选按频率排序，槽0不保证是最大峰。

probe5/6/7/9为实时诊断，其他字段为原子快照。解码器的candidate_snapshot提供拒绝前候选，component_snapshot提供最终qualified分量；候选非零不代表测量有效。epoch与同帧有效位必须一起使用。

## 状态与故障码

| diagnostic_status位 | 含义 |
| --- | --- |
| 31:28 | error_code：1超时、2采集期间原始ADC碰轨、F非法状态 |
| 27:25 | run_state：0 IDLE、1 ARMED、2 RUN、3 DRAIN、4 FAULT |
| 24:20 | 去抖开关{SW15,SW3,SW2,SW1,SW0} |
| 19 / 18 / 17 | capture_enable / controller_release / capture_start |
| 16 / 15 / 14 / 13 | 实时frame/time/FFT/peak完成脉冲 |
| 12 | 当前HMI信号有效 |
| 11 / 10 / 9 / 8 / 7 | capture/time/FFT/peak/HMI忙 |
| 6 / 5 | packet_finished / acquisition_fault |
| 4:0 | 本事务已出现frame/time/FFT/peak/快照事件 |

故障码保持到复位，新帧成功不自动清除；不能单独用error_code=1判断当前帧超时。frame_id在算法复位后重计，不是跨上电永久ID。1024个算法采样仅覆盖约42个独立ADC更新，不是8192点完整波形，不能认证全帧无触轨或完整频谱。

## 横杠与约189kHz背景

1. 保留当前现场，不先复位。核对源状态和活动模式、单次/连续。
2. 若纯正弦主峰正确，却另有约bin378/379弱候选，优先关闭OUT并检查BNC/SMA、供电和共地，再用相同设置捕获新帧。已有[10月23日](bnc_recovery_20261023.md)与[11月6日](../reports/single_tone_reseat_20261106/README.md)恢复证据。
3. 比较qualified、候选数/幅值、背景、RMS和事件链；额外候选可因谐波一致性使整帧无效。不要为了接触问题盲目提高门限或固定屏蔽189kHz。
4. 频点与历史接近不单独证明来源；连接复查无效时再取完整频谱/时域证据并排查数字链路。

旧十探针及schema2交接记录见[原ILA文档](ila_diagnostics_history_20261106.md)、[同帧快照设计历史](measurement_debug_snapshot_20261024.md)，不作为当前探针语义。
