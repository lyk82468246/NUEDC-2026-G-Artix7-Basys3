# 三分量幅值快照首次实板验证（2026-10-24）

## 手动构建版本

用户完成15探针ILA配置、综合、实现、生成bit/LTX并烧写；助手不构建、program或复位。源版本为66632a3，FIR均衡及VIO接口不改。

- bit：2026-10-24 00:33:02，`G_FPGA.runs/impl_1/G_FPGA_Top.bit`，SHA256 `DA9933BF46BD20C35F7ED639FCB69F70F8123F6155CDE7CE99213243DED80E30`。
- 新LTX：同一时间，SHA256 `764CAF1247814E5058BC1700A516AE1AFB9C74063D93B3071CB17E0D73CBB45C`；不是旧十探针LTX。
- routed报告WNS +0.128ns、WHS +0.019ns、TNS/THS 0，报告声明用户指定约束满足。placed报告Block RAM Tile=47/50（94%）、LUT=12862/20800（61.84%）；剩余BRAM仅3块，不能轻率继续加深ILA或全帧缓存。
- 报告存档：`reports/manual_gui_debug_snapshot_20261024_{timing,utilization}.rpt`。这是用户构建产物，不是助手启动构建。

## 输出关闭预检与参数加载

UTG CH1→原滤波器→AD9226→FPGA，CH2保持OFF；B/连续，屏幕未接。启动UTG双通道查询均OFF，CH1原为50kHz重复频率、100mVpp满量程、HIGHZ、0V、用户ARB槽1。

OFF新帧位于`test_results/debug_schema_off_initial_20261024`：恰有一个debug_measurement_valid，raw Vpp30/RMS4，基波及全部槽位索引/幅值0，count0、frame_id6098、epoch0；signal_valid=0、calibration_present=1、calibration_enabled=0、mode1/B、连续、error0、acquisition_fault=0。说明实际新LTX名称、完整位宽和host schema2已读通，不只是离线mock。

00:35:13通过VIO原子加载存档临时参数Vpp3623460、RMS3701829、FFT4194，active回读匹配、epoch1、enabled1；UTG期间保持OFF。日志`test_results/debug_schema_apply_20261024`。仍是由HDS HIGHZ设定建立的参考µV/raw，不是新测输入电压；不为适配UTG而重拟合增益。

## 同帧三分量试验

使用`utg_fpga_trial.py`，相同三个固定案例各两帧：100kHz单音；50/150/200kHz的60/25/15mVpp、0/0/0度；50/150/200kHz的10/50/40mVpp、0/90/0度。总设定包络≤100mVpp、高阻、零偏置，CH2从未开启。理论Vpp/RMS及观测边界见[此前同向量记录](utg_multitone_hardware_20261023.md)。每案例成功或异常后均关闭两路，前案例失败不会继续后案例。

新schema直接观测三个排序槽位的32bit raw幅值，与同帧count/bins/frame_id/epoch对应，按存档FFT比例离线换算分量正弦峰值。不是VIO的校准输出包，不是独立仪器测得的输入幅值；所有分量共用同一临时FFT比例。

## 结果

三个案例各两帧完整完成。每帧一个新measurement_valid，控制位4（B/连续），signal_valid=1、error_code=0、acquisition_fault=0；全部快照保持稳定，VIO存在且已启用，epoch均1。帧号依次14690/14753、15190/15254、15764/15836，无重复；连续模式会跳过未被主机捕获的帧，不要求相邻采集编号只增加1。

| 案例 | 输出基频 | 各分量峰值设定参考mV | 两帧测得分量峰值参考mV | 两帧Vpp参考mV | RMS参考mV |
| --- | --- | --- | --- | --- | --- |
| 单音 | 100kHz | 50 | 51.243 / 51.239 | 101.456 / 101.622 | 36.207 |
| 普通三音 | 50kHz | 30 / 12.5 / 7.5 | 30.534,12.714,7.655 / 30.520,12.710,7.636 | 69.167 / 69.665 | 24.006 |
| 弱基波/强谐波 | 50kHz | 5 / 25 / 20 | 5.105,25.411,20.308 / 5.104,25.398,20.330 | 88.298 / 88.408 | 23.272 |

三音候选均[100,300,400]、count=3；单音[200,0,0]、count=1，未使用幅值槽位为0。普通三音raw幅值分别[477131,198672,119623]及[476904,198609,119315]；弱基波case分别[79774,397077,317331]及[79749,396870,317675]。最强150kHz分量没有被误当基频，幅值槽位依频率排序而非幅度排序。

两组三音四帧所有分量的最大峰值参考偏差0.534mV；计入单音六帧，最大分量峰值偏差1.243mV、Vpp1.622mV、RMS0.85167mV。仅三音的Vpp最大偏差1.14448mV、RMS0.42105mV。均通过本轮≤5mV的**设定值参考一致性**限值，不能表述为独立绝对电压校准或全A/B/C验收。

汇总[六帧完整幅值分析](component_amplitudes_20261024_analysis.json)：`all_component_amplitudes_observed=true`、`overall_pass=true`，scope为Vpp/RMS/全部已检出分量峰值/候选频率，`absolute_input_calibrated=false`。电压仍为主机将raw按存档比例换算，非VIO测量输出或实屏读数。

收尾OFF新帧位于`test_results/debug_fullamp_off_final_20261024`：frame_id20217、epoch1、calibration_enabled=1，count0、三个索引/幅值均0、基波0，Vpp32/RMS4 raw、signal_valid=0，控制位及故障诊断正常。证明强三音之后的无信号快照不残留分量。最终UTG双通道查询再次确认OFF；CH1保留强谐波ARB配置但未开启，CH2设置不变。

## 归档和下一步

原始ILA、参数前后回读、上传表和关断记录位于`test_results/debug_fullamp_{sine,harmonic,strong_harmonic}_20261024`；不重用旧截图，完整事务成功后才归档机器报告。用户手动构建生成的xpr/ILA输出产物一并同步，助手本轮未修改RTL或重新生成IP。

下一步可用相同安全包络扩展到125/375/500kHz复合信号及离栅格基波/谐波，之后再讨论量程扩展。250mVpp及200mVpp干扰仍未授权输出，也未测试；C抗混叠、独立幅相参考、A模式控制、实屏和2秒端到端仍未验收。
