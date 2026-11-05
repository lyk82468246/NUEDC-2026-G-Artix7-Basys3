# AFG1022标定中断与单音资格诊断

2026-11-05。用户要求使用AFG1022标定，并明确使用HIGHZ显示约定。本轮未执行Runtime apply、Flash save、综合、实现、bit生成或下载；用户曾手动重新下载既有程序。原系数3623460/3701829/4194及A槽记录保持不变，不能将本轮称为标定完成。

## 三组实板对照

AFG1022序列1931131，固件V1.2.4；CH1、HIGHZ、零偏置，调制/扫频/突发关闭。FPGA为A模式连续采集、旧schema2 ILA。每组采集前后源状态回读一致，均触发新的measurement_valid；不是用历史寄存器充当新帧。

| 输入 | 实际基频/分量 | 源幅度设置 | raw Vpp/RMS | 频域结果 |
| --- | --- | --- | --- | --- |
| 原生SIN | 100 kHz单音 | 200 mVpp | 3691 / 1286 | 无效，基频/幅值/有效槽均0 |
| EMEM纯正弦 | 8192点、64周期、整表1562.5 Hz，即100 kHz单音 | 200 mVpp | 3692 / 1286 | 同样无效 |
| Tk GUI A默认配方 | 50/150/200 kHz；峰值60/25/15 mV，相位全0 | 整表390.625 Hz，满量程200 mVpp；不是复合波实际Vpp | 2540 / 857 | 有效，bins=100/300/400，raw幅值962458/399769/239596 |

各目录保存真实ILA CSV与前后设置、同帧元数据JSON：[原生SIN](native_sine/record.json)、[EMEM单音](emem_single/record.json)、[GUI复合波](gui_A_preset/record.json)。EMEM上传覆盖前的原始DAC表另行备份在本地忽略的`test_results/afg_single_vs_gui_20261105/emem_backup_codes.json`。测试结束两路输出均OFF；最后CH1保留GUI默认配方的EMEM配置。

此结果排除了“只有原生SIN生成方式不工作”的解释，但没有识别实板被拒绝的具体候选峰。早先100kHz、100～250mVpp HIGHZ扫描的Vpp/RMS近似线性，旧系数换算约高2%～3%；其频域无效，因此没有把它们用于FFT标定，也没有据此改变系数。此前50Ω设置试验不属于此次HIGHZ拟合基准。

## 单音拒绝与周期触发的关系

`Display_HMI`先在peak_result_valid锁存信号资格及候选分量，have_time/have_peak齐备后发布measurement_valid，然后进入WAVE_START。用于显示一个/三个周期的`Display_Fundamental_Aligner`此后才工作，只改变冻结时域帧的屏幕取点坐标，不反馈FFT输入。因此已观测到的“本帧频域资格拒绝”不应直接归因于随后才执行的显示锁相。

ADC采集过零触发是独立的前级路径，尚未由此排除。实时ADC短窗口拟合频率接近100kHz，OFF时RMS约4、ON时随幅度增加；短窗口估计不能充当精确频率或无失真的证明。

源代码复核和新增仿真证明：理想bin200单峰能被识别；背景100、主峰1600000、额外bin193=10000和bin207=8000时，额外峰超过相对及背景门限，最终谐波一致性失败，清零基频。此合成案例说明一种可能机制，**不是对实板额外峰位置的推断结论**。检测阈值和一致性算法本轮没有修改。

## schema3只读诊断修订

`DEBUG_RAW_CANDIDATES=1`为顶层新默认值，重用现有probe8/10/11的36/96/2位寄存器，在同帧快照中保留Component_Analyzer的未屏蔽count/bins/magnitudes。metadata bit7=1标识schema3；bit0仍表示测量是否通过资格判断，probe3/4仍为限定后的基频幅值/索引。未使用槽仍清零。设DEBUG_RAW_CANDIDATES=0可恢复schema2行为。

这些“原始候选”指经过现有相对/噪声门限后、谐波资格判决前的候选，并非完整FFT或未过滤的所有谱峰。现有屏幕、Run_Controller、Runtime_Calibration及Flash记录格式不变。

主机inspect_ila.py同时支持schema2/3：schema3额外返回candidate_snapshot；component_snapshot仍只提供合格分量，不能将被拒绝候选误用为标定值。0候选与非0候选但被拒绝，现在可以区分。背景估计probe9仍是实时诊断，不属于该原子快照。

不新增ILA端口、宽度、采样深度、DSP或BRAM存储；复用原有快照字段，增加直接观察连线。资源及时序仍以新实现为准。新增诊断不是修复单音拒绝本身。

## 验证与下一步

主机154项测试通过（包括schema3原始候选不能被解释为有效分量）；旧schema2与schema3快照仿真均通过。谱峰分析器仿真通过既有复合波夹具、理想单峰和不一致微弱峰案例。实际顶层以黑盒算法IP验证诊断连线与功能消费者隔离；不声称完整算法IP数值仿真。

用户下一次手动综合/实现后检查时序、下载bit及匹配LTX；不需重新生成ILA IP，也不必写配置Flash。随后采集相同单音，读取candidate_snapshot以确定是空谱还是被额外峰否决，再决定修订判决或排查模拟/采样链路。新诊断版本尚未构建、下载或完成实板读回。

## 插拔与启动边界

中途USB重新插拔时用户报告DONE短闪、其余全灭；只读寄存器显示DONE=0、EOS=0、模式001（Master SPI）、CRC/ID错误0，用户按PROG未恢复。后续用户报告独立5V且未连接电脑时可从Flash启动，并重新JTAG下载恢复测试。电脑/JTAG接入相关性已观察到，具体机制未确定；不能据此保证所有USB连接条件下可靠自启动。没有为排查擦除Flash或改写参数。
