# Vivado手动构建交接

2026-10-23起按用户约定：助手编辑RTL、工程注册、约束及文档并进行约定的离线检查；综合、实现、生成bit及烧写均由用户在Vivado中操作。助手先通知准备状态，等待用户反馈再继续。不因旧阶段曾授权自动构建而重新启动这些操作。

## 1. 本次module not found

`Component_Analyzer.v`存在且模块名正确，但用户13:51失败的综合工程没有将它加入源文件列表。检查时磁盘`G_FPGA.xpr`也缺这条注册；已补回并启用synthesis/implementation/simulation。此前工程保存、备份恢复与GUI旧会话没有可靠同步，不能把这个问题归咎于用户改动工具链。

仅修改磁盘XPR不会更新已经打开的GUI内存工程。请在当前Vivado的Tcl Console执行以下**仅注册**命令：

```tcl
source {C:/Users/Joe/Documents/Verilog/G_FPGA/scripts/setup_contest.tcl}
```

应打印`PASS: Component_Analyzer registered, enabled, and included in synthesis compile order.`。脚本会加入必要RTL、启用用途、更新编译顺序并检查Component_Analyzer确实出现在综合编译顺序中；不会关闭工程、重置运行、生成IP、综合、实现或烧写。之后在Sources中应能看到Component_Analyzer，不再是缺失模块。

本次交接只请先手动Run Synthesis；若提示重置失败运行，由用户确认。完成后告知助手状态或首个报错，尚不自动进入实现。后续用户正常保存工程；若重新打开则打开本仓库根目录的`G_FPGA.xpr`，避免另一个副本或旧GUI会话覆盖源列表。

## 2. 为什么以前GUI不显示成功

此前为规避本机Windows Script Host包装器及Vivado路径处理问题，使用临时`SUBST V:`映射本仓库，再在batch中直接调用`synth_design`、`place_design`、`route_design`、`write_bitstream`。这仍是同一个物理仓库，并非另一个工程目录。结果曾写入根目录下`G_FPGA.runs/impl_1`，但直接命令绕过了GUI标准`synth_1/impl_1`运行状态管理，不能据此期待GUI自动显示“Complete”或能直接Open Synthesized Design。

此外，已打开GUI持有内存源列表；脚本修改/恢复磁盘XPR并不能同步它。本次缺源说明这条工作流没有可靠交接，今后以用户GUI工程和标准运行作为构建依据。旧脚本保留为历史工具，助手不自行运行。

## 3. 标准GUI结果位置

| GUI步骤 | 常规结果位置（仓库内） |
| --- | --- |
| Run Synthesis | `G_FPGA.runs/synth_1/G_FPGA_Top.dcp`及`runme.log` |
| Run Implementation | `G_FPGA.runs/impl_1/G_FPGA_Top_routed.dcp`及实现报告 |
| Generate Bitstream | `G_FPGA.runs/impl_1/G_FPGA_Top.bit`，启用ILA时配套LTX也应核对 |

以上是预期路径，不代表文件当前已经存在。13:50本机运行目录重新生成了GUI运行脚本；本次检查时`impl_1`仅有运行辅助文件，没有bit、LTX或routed DCP。重置/重新生成运行可能清理旧结果，不应把历史报告当作本轮手动运行结果。

`test_results/p3_diagnostic_20261023/G_FPGA_Top.bit/.ltx`是**诊断构建前备份的六探针P3旧版**，不是十探针诊断版。不要因目录名带diagnostic便把它当成最新版。bit与LTX必须成对匹配，使用本轮GUI生成结果并记录散列。

## 4. 历史记录与当前边界

中断前十探针诊断版曾于13:21完成脚本构建：WNS+0.097ns、WHS+0.026ns、DRC 0错误/14警告，BRAM42/50、DSP75/90；13:22下载成功。bit SHA256=`FE1259F1D9871635ABBDFD8851D8068246533BCC6658F448133549EBA671930F`，LTX SHA256=`5CD7AB9F4D15596F6FDB8F31EF01C4F9281150B8C531FECD96C8DA3FE261B881`。这是历史结果，不能作为修订后GUI综合成功的证明。

用户随后确认先前不慎断开过ADC电源，现在已恢复，因此按用户要求停止针对该次超时的RTL排查；仍保留原始日志，不把该次异常当成已证实的RTL缺陷。网络中断期间自动计划未完成有效单音验证，不能补记通过。13:57重新连接仪器、明确关闭OUT并确认成功，随后停止服务。本次源注册修复后没有启动综合、实现、生成bit或烧写；等待用户操作。

## 5. 用户已完成本轮手动构建

用户随后在GUI成功加入Component_Analyzer，并完成综合、实现、生成bit和烧写。14:24生成的GUI bit（SHA以F92E2892开头）不同于13:21脚本bit；LTX布局相同，但仍需按本轮产物成对使用。GUI报告及实测详见[GUI硬件记录](hardware_gui_20261023.md)。助手后续只读报告和ILA、运行约定的信号源测试，未代替用户执行新的构建或烧写；修复未来RTL后仍须再次通知并等待用户操作。
