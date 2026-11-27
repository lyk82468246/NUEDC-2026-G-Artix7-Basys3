# 2026-11-27 启动镜像升级与系数保留验证

RTL提交为`e723d26`，本轮修复wave横向发送方向。用户手动完成综合、实现、生成bit、JTAG下载、Flash烧写及重新上电，并确认实屏方向符合预期，连接信号发生器实测正常。此次没有提供频点、幅值及误差表，不能将这次功能复测扩展为全部指标的定量验收。

## 构建与镜像

Vivado 2025.2，bit/LTX生成时间为2026-11-27 11:17:48。布线时序报告11:16:31，WNS +0.123 ns、WHS +0.016 ns、TNS/THS 0。同轮placed资源为LUT 20017/20800、FF 28709/41600、BRAM 48.5/50、DSP 90/90。routed DRC有53项Warning、无Error。原有ADC外部时序和CDC假设仍需独立核验，内部时序通过不代替外部接口签核。

- [布线时序原始报告](G_FPGA_Top_timing_summary_routed.rpt)
- [同轮placed资源原始报告](G_FPGA_Top_utilization_placed.rpt)
- [布线DRC原始报告](G_FPGA_Top_drc_routed.rpt)
- [版本、产物SHA256与系数清单](manifest.json)
- [MCS地址审计](mcs.audit.json)
- [用户控制台节选](hardware_console_excerpt.txt)，省略脚本定义回显，遮去目标序列号

MCS为`boot_20261127_wavefix_e723d26.mcs`，从0地址加载。实际数据末地址为`0x1BAA5F`，按64 KiB扇区对齐后，擦除范围上界为`0x1C0000`（不含）。系数区从`0x3E0000`开始，二者不相交。MCS中的4 MiB整片容量标注不等于数据覆盖整片或需要整片擦除。

## Flash升级前后对比

| 项目 | 升级前 | 重新上电后 |
| --- | --- | --- |
| saved_valid / source | 1 / 2（B槽） | 1 / 2（B槽） |
| sequence / saved_epoch | 1 / 2 | 1 / 2 |
| bank | 79294142238186840429235802095 | 79294142238186840429235802095 |
| active bank | 与saved相同 | 与saved相同 |
| active epoch | 1 | 1 |
| dirty / error | 0 / 0 | 0 / 0 |
| Vpp / RMS / FFT系数 | 3576768 / 3601627 / 4079 | 3576768 / 3601627 / 4079 |

系数为unsigned Q16.16 µV/raw，FFT对应正弦峰值。升级前`rc_export`备份与控制台一致。烧写设置`PROGRAM.ADDRESS_RANGE=use_file`，日志明确记录Erase成功、Program/Verify成功。用户确认重新上电，随后控制台仅重连并关联LTX，没有再次JTAG下载应用程序，即可识别1个ILA和2个VIO并读到原有效B槽及活动bank。结合用户实屏与信号源测试，支持本板此次Flash启动与标定恢复成功的结论。未对整个参数分区做逐字节转储比对。

## 日志中的提示

Flash编程前Vivado临时加载SPI访问程序，因此该阶段原应用程序的ILA/VIO不在器件内，出现`Labtools 27-3413 Dropping logic core`。Flash编程及校验均已成功，恢复启动后识别1 ILA、2 VIO，没有持续探针不匹配证据。

烧写成功后出现一次`44-513 HW Target shutdown`，之后成功重连。用户确认执行重新上电，该断连与此相容，日志本身不能单独确定断连原因。恢复后的读取正常，因此没有显示此次烧录失败的证据。

## 发布范围

发布`v2026.11.27`，保留`v2026.11.13`历史版本。新Release包含本轮bit、匹配`debug_nets.ltx`、MCS、MCS审计、manifest和SHA256清单。报告PDF沿用`1b62b05`版本，仍含原报告的历史硬件基线，不将其旧资源/时序数据自动解释为本轮结果。

后续烧写仍须选择Configuration File Only / `use_file`并执行Verify，禁止Entire Device整片擦除。发布MCS不含用户标定记录；已有效保存的标定由板上参数区恢复，空白Flash不会凭此MCS获得本板校准值。
