# 双页显示版本：用户手动构建核对

核对日期：2026-10-30；构建由用户在Vivado GUI执行。助手在修订README时只读已有报告、日志及产物，未运行综合、实现、bit生成、烧写或硬件读回。

## 结果

本轮报告时间09:06:05，bit生成结束09:06:50，仓库核对时HEAD为`c6b70a5`。这次构建已包含显示算术分拍、逐字节命令构造和分组复位修订。没有用户确认或JTAG读回证明此bit已下载，不能把生成产物当成实板验收。

| 项目 | 结果 |
| --- | --- |
| WNS / TNS | +0.447 ns / 0 ns，setup失败端点0 |
| WHS / THS | +0.013 ns / 0 ns，hold失败端点0 |
| 内部未约束端点 | 0；已有I/O延迟/CDC假设仍须独立核验 |
| bitgen前DRC | 0错误 |
| 构建结束日志 | 168 Infos、3 Warnings、0 Critical Warnings、0 Errors |
| Slice LUT | 14948 / 20800，71.87% |
| Slice寄存器 | 23767 / 41600，57.13% |
| BRAM Tile | 47 / 50，94.00% |
| DSP | 89 / 90，98.89% |

满足**当前已指定约束**。剩余DSP/BRAM资源较少，新增算法须重新核算；当前结果不验收实际ADC外部时序、模拟精度、屏幕布局或两秒响应。

证据摘录：[时序摘要](../reports/manual_gui_display_20261030_timing_summary.rpt)、[放置资源报告](../reports/manual_gui_display_20261030_utilization.rpt)。前者仅归档原始报告的摘要部分，不是全路径报告。08:43时序失败的原始记录继续保留在[修订记录](../reports/display_timing_20261030/README.md)。

## 下载产物

| 文件 | 大小 | SHA-256 |
| --- | --- | --- |
| G_FPGA.runs/impl_1/G_FPGA_Top.bit | 1712624 bytes | `FEA7E83AE8BE598F10B9349370AFB4BE65F1352C2EF4547D5BE9BFF95D419973` |
| G_FPGA.runs/impl_1/debug_nets.ltx | 166383 bytes | `764CAF1247814E5058BC1700A516AE1AFB9C74063D93B3071CB17E0D73CBB45C` |

LTX散列与此前15探针布局相同，是探针定义保持兼容的结果；bit已经不同，不能据LTX相同认定板上逻辑已更新。下载时仍应选择本轮生成的一对文件。已有Flash镜像不在此次核对范围内，也未改写。
