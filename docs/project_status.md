# 当前版本与验证状态

核对日期：2026-11-06。本页集中记录当前程序、活动标定和验证边界；操作方法见[文档导航](README.md)。历史报告仅对其记录的构建及接线有效。

## 程序与调试文件

| 项目 | 当前记录 |
| --- | --- |
| RTL功能版本 | `e733a9e`：修复FFT平顶窗ROM使能/读取配对；包含schema3原始候选诊断 |
| bit | `G_FPGA.runs/impl_1/G_FPGA_Top.bit`，2026-11-06 08:33:21 |
| LTX | 同目录`debug_nets.ltx`，08:33:22；1 ILA、2 VIO |
| 实现时序 | WNS +0.280 ns、WHS +0.011 ns、TNS/THS 0；报告08:32:08 |
| 当前启动镜像 | `test_results/p2_boot_20261106_romfix_e733a9e.mcs`；用户确认已烧写并成功加载 |
| 旧启动镜像 | `test_results/p2_boot_01.mcs`为11月5日22:27版，不能当作最新版重烧 |

[MCS地址审计与bit哈希](../reports/boot_mcs_20261106/README.md)用于对应本地文件；不等于读回器件全部配置位。运行目录和MCS是本地生成产物，不随Git克隆自动出现。当前Git后续提交包括文档和测试数据，不要求每次重新生成硬件。

## 标定状态

| 项目 | 当前活动/Flash保存值 | RTL回退默认值 |
| --- | ---: | ---: |
| Vpp / 波形Amax系数 | 3576768 | 3623460 |
| RMS系数 | 3601627 | 3701829 |
| FFT正弦峰值系数 | 4079 | 4194 |

均为unsigned Q16.16 µV/raw。2026-11-06在线应用epoch2，B槽source2、sequence1、saved_epoch2，保存回读`SAVED_AND_VERIFIED`、dirty0、error0；保存与活动bank一致。[原始数据与验证](../reports/afg_calibration_20261106/README.md)包含100kHz四点拟合、125/225mVpp独立幅值验证、175mVpp实际VIO输出和10/200kHz检查。

参考是AFG1022 **HIGHZ显示设定值**，不是连接器端独立绝对电压标定。FFT幅值为正弦峰值，不是Vpp或RMS。当前记录优先于RTL默认值；无需重生成bit/MCS。该新B槽尚未做本轮断电恢复复测，不能用此前A槽冷启动记录替代。

## 已验证与待验证

| 范围 | 结论与证据 |
| --- | --- |
| ROM时序 | 真实IP三帧/24576点加窗输入检查、强制AXI背压及旧版负对照通过；[报告](../reports/fft_window_alignment_fix_20261106/README.md) |
| 单音散点失效 | BNC/SMA重新连接后11/12/42/100kHz均变为单候选有效帧；[前后对照](../reports/single_tone_reseat_20261106/README.md) |
| 约189kHz弱峰经验 | 10月23日及11月6日均有接触恢复前后对照；重现时优先检查连接，不先改算法门限或写固定陷波 |
| 标定持久化 | 旧A槽save/免擦写/reload/BtnC/重新配置/断电恢复已测；本次B槽轮换save和导出核对已测；[旧恢复证据](../reports/flash_persistence_20261105/README.md) |
| 显示 | 当前bit包含同页不重复page、频谱方向修正、kHz文本、带限波形插值；实际控件/尺寸及完整组合波显示仍需实屏验收 |
| 待验收 | 新B槽断电恢复、独立绝对电压精度、长期/全频段重复性、多音/弱基波、完整C模式干扰、ADC外部时序/CDC假设、端到端≤2s |

## 现场优先处理顺序

1. 再现固定约189～192kHz弱峰或单音横杠时，先关闭OUT，检查BNC/SMA锁紧、共地及电源，再用相同源设置作新帧前后对照。频率接近是经验线索，不单独证明振荡机理。
2. 确认源为HIGHZ、CW、0V偏置，频率与幅值回读一致；不要把旧ILA capture当实时数据。
3. 通过schema3看原始候选与qualified结果，区分采集超时、无信号和谐波一致性拒绝。故障码锁存到复位，成功新帧不自动清除。
4. 连接稳定后再做[现场验收](contest_acceptance_runbook.md)与标定复核。

当前没有A模式Vpp低于100mV或高于250mV就拒绝的代码；主要有效性门控是谱/谐波判定和RMS raw≥64。A模式搜索bin20～400（10～200kHz），不能把题目幅值适用范围误读为RTL硬拒绝范围。

## 供电与尺寸范围更正（用户最新确认）

整机外部只有一路直流+5 V，内部先用现成Boost升至12 V，再接所称MP5418模块产生±5 V；用户确认单点共地、电脑USB不参与供电。Basys3、AD9226模块和串口屏直接接外部+5 V，转换后的±5 V仅供SGM8302；不再把±5 V模拟轨解释为违反单路供电。屏幕≥6英寸仅由用户允许放宽项目范围，未核实官方豁免。详见[完整审计及报告素材](report_materials_2026-11-06.md)。本次设备均已脱机，没有新硬件实验。

## 同轮资源与外部时序审计

11月6日08:28 placed报告：LUT19887/20800、FF28675/41600、BRAM48.5/50、DSP90/90；同轮routed DRC为52项Warning、methodology为90项Warning，check_timing仍有11个输入/29个输出缺少延迟约束。没有把placed资源称为另跑的post-route资源，也不以正WNS证明外部ADC接口已独立验收。原始报告已归档到[离线审计证据](../reports/report_audit_20261106/README.md)，完整说明见[报告素材](report_materials_2026-11-06.md)。
