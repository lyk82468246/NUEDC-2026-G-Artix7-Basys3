# 2026-10-30 显示集成时序违例与 RTL 修订

## 用户手动实现的原始结果

08:43:50 routed报告：WNS **-4.383ns**、TNS **-3948.902ns**、3106个setup失败端点；WHS +0.008ns。100MHz算法时钟10ns，内部无未约束端点。放置后LUT15765/20800（75.79%），寄存器22430/41600（53.92%）。这些全是**修订前**产物数据。

08:44工具仍生成了bit，说明“Bitgen Completed”不等于时序合格；此bit不能作为通过版本使用。I/O delay等原有约束边界仍须另行验收，本次没有用忽略路径或放宽时钟修饰内部违例。

原始摘要归档为 `before_summary.rpt`。助手只读打开现有 `G_FPGA.runs/impl_1/G_FPGA_Top_routed.dcp`，导出 `before_worst100.rpt/.tsv`；没有综合、优化、放置、布线、生成IP/bit或烧写，没有保存/关闭用户GUI工程。前100条按source归类：频谱12条、文本13条、算法复位75条；不是全部3106端点的完整分类。

## 定位与修订

| 证据 | 原因 | RTL处理 |
| --- | --- | --- |
| slot→u_spec/u_div/dividend[45]，-4.383ns，数据路径14.213ns，16级含2个DSP | 三选一、宽减法、乘法、舍入、除法输入寄存连在一拍 | Display_Spectrum_Renderer按选择/差分/两路16×16部分积/合并/舍入/除法握手分拍，X/Y共用运算流程 |
| text_value[99]→command_length[2]，-4.324ns，路径14.162ns，其中路由11.846ns | 数据相关的宽移位、宽字符串长度优先选择和高扇出 | Display_HMI逐字节构造控件名、后缀、数值、引号；Hz逐位BCD输出；literal长度逐字节扫描，不再对动态文本做512bit长度优先编码 |
| reset_sync_algo→FFT/显示reset端，约-3.685ns及以下 | 单个算法复位信号驱动大量寄存器导致长路由 | 子系统按ADC/AFE/时域/FFT/谱峰/HMI分组注册同步复位；HMI内部再按FSM及子模块分组，DONT_TOUCH保留相同延迟的本地副本 |

Display_Unsigned_Divider同时用一个带借位减法结果生成比较和差值，避免独立宽比较器接第二个减法器。没有新增时钟域、IP或整帧BRAM，没有修改XDC和测量公式；仅增加少量处理周期。各级本地复位固定增加一拍，仍在同一100MHz域，同组FSM/消费者等延迟；原始异步输入复位同步器继续保留。

## 已验证与尚未验证

- `hmi.log`：3个端到端UART测试顶层通过，包括完整8192点/240像素、翻转、周期重同步、每条命令/每个点、同帧gain/epoch、HOLD重绘、无信号/缺失槽、复位中断和最后停止位后释放。
- `prepare.log`：240×160、200×128、17×256三组数学对照通过，含满32位幅值、除法零分母、背压和复位。数值与旧版保持一致，不固定旧版处理延迟。
- `top.log`：快照和真实顶层VIO开/关、新旧HMI连接、采集许可保护两组通过；DSP IP仍黑盒。
- `host.log`：110项离线主机回归通过，无仪器/JTAG访问。

**新RTL尚未重新综合/实现，不能宣称WNS已转正。** 下一步由用户在原GUI工程重新综合及实现，检查WNS/WHS、资源与DRC后再生成bit。无需新增源码注册或重新生成IP，本次没有改用户的xpr、导入DCP或Flash文件。若下一次仍违例，应以新的routed报告定位剩余路径；不要复用本文旧WNS当成新结果。

复现行为仿真：`run_display_hmi_sim.ps1`、`run_display_prepare_sim.ps1`、`run_measurement_debug_sim.ps1`。只读检查点脚本为 `scripts/report_display_timing_checkpoint.tcl`，其输出始终属于读取时的检查点，而非未构建RTL；归档before报告不要用未来结果覆盖。
