# Vivado手动构建、下载与Flash升级

综合、实现、生成bit及烧写由用户在Vivado中手动执行；助手可编辑源码、做离线仿真和读取产物。仅离线生成MCS时可按用户请求调用既有镜像脚本。当前产物与保存系数见[当前状态](project_status.md)。

## 判断是否需要重建

| 变化 | 需要的操作 |
| --- | --- |
| 文档/主机分析脚本 | 不重建FPGA |
| 在线标定系数 | VIO apply、验证、save；不生成bit/MCS |
| RTL/约束变化 | 用户重新综合、实现、检查时序/DRC、生成bit |
| IP配置/探针端口变化 | 先更新对应IP产物/OOC，再完整构建 |
| 希望断电后仍启动新逻辑 | 从通过验证的bit生成新MCS，由用户烧写配置Flash |

## 在原GUI工程构建

1. 打开仓库根目录`G_FPGA.xpr`，top为`G_FPGA_Top`，器件为`xc7a35tcpg236-1`。不要另开旧副本。
2. 外部修改磁盘XPR不会同步已打开的GUI源列表。新增RTL后按需执行注册脚本并保存工程；普通文件内容更新不需要每次重装IP：

```tcl
source C:/Users/Joe/Documents/Verilog/G_FPGA/scripts/setup_contest.tcl
source C:/Users/Joe/Documents/Verilog/G_FPGA/scripts/setup_display_prepare.tcl
```

当前P2需要generic启用`ENABLE_RUNTIME_CALIBRATION=1`、`ENABLE_FLASH_PERSISTENCE=1`、`ENABLE_FLASH_READONLY_PROBE=0`；顶层参数缺省不等于工程generic。既有工程已具备功能，不应为检查状态反复运行首次IP安装脚本。

3. 用户运行Synthesis → Implementation，检查setup/hold、DRC、资源及未约束路径，再Generate Bitstream。不得用旧报告签核新源码。
4. 若提示module not found，确认文件在Sources中、模块名正确、USED_IN_SYNTHESIS启用，参见[登记问题](synthesis_source_registration_20261030.md)。

| 产物 | 常规路径 |
| --- | --- |
| 综合 | `G_FPGA.runs/synth_1/` |
| 布线时序 | `G_FPGA.runs/impl_1/G_FPGA_Top_timing_summary_routed.rpt` |
| 程序 | `G_FPGA.runs/impl_1/G_FPGA_Top.bit` |
| 探针 | `G_FPGA.runs/impl_1/debug_nets.ltx` |

SUBST盘符仅可能用于Windows工具路径兼容，不代表另一个物理工程。日常使用GUI标准runs；早期直接调用place/route脚本绕过了GUI运行状态管理，该方式不再作为日常流程。[历史原因](manual_vivado_workflow_history_20261106.md)保留追溯。

## JTAG下载和匹配LTX

Hardware Manager连接板卡后，Program Device选择同一轮bit与LTX。JTAG下载只更新易失配置，不更新启动Flash。若重新上电加载Flash版，必须为该版使用匹配LTX；出现UUID/端口数不匹配应先解决版本对应，不强行忽略。

仅给已经运行的当前版关联LTX（不下载程序）：

```tcl
set dev [current_hw_device]
set_property PROBES.FILE {C:/Users/Joe/Documents/Verilog/G_FPGA/G_FPGA.runs/impl_1/debug_nets.ltx} $dev
refresh_hw_device $dev
```

已存在cfgmem对象时，“Add Configuration Memory Device”灰色不代表故障：`get_hw_cfgmems`及`get_property PROGRAM.HW_CFGMEM $dev`可查询已有对象。

## 离线生成新MCS

当前已烧写镜像为`test_results/p2_boot_20261106_romfix_e733a9e.mcs`。以下模板用于未来升级，输出必须用尚不存在的新名称：

```tcl
source C:/Users/Joe/Documents/Verilog/G_FPGA/scripts/create_boot_mcs.tcl
rc_create_boot_mcs C:/Users/Joe/Documents/Verilog/G_FPGA/G_FPGA.runs/impl_1/G_FPGA_Top.bit C:/Users/Joe/Documents/Verilog/G_FPGA/test_results/boot_next_unique.mcs
```

脚本不连接硬件；SPIx1、4MiB，从0地址加载，并以项目Python `-E`审计地址范围和bit/MCS哈希。`-E`避免Vivado的PYTHONHOME污染导致SRE module mismatch。审计通过才发布最终MCS。不要根据文件名或时间单独判定程序版本，保留audit.json。

## 用户手动烧写配置Flash

先导出系数，然后为已有cfgmem对象选择新镜像。以下设置本身不开始擦写：

```tcl
set dev [current_hw_device]
set mem [get_property PROGRAM.HW_CFGMEM $dev]
# 若mem为空，先按板载MX25L3233 / JEDEC C22016选择兼容profile
set_property PROGRAM.FILES {C:/Users/Joe/Documents/Verilog/G_FPGA/test_results/boot_next_unique.mcs} $mem
set_property PROGRAM.ADDRESS_RANGE {use_file} $mem
set_property PROGRAM.ERASE 1 $mem
set_property PROGRAM.CFG_PROGRAM 1 $mem
set_property PROGRAM.VERIFY 1 $mem
set_property PROGRAM.BLANK_CHECK 0 $mem
puts [get_property PROGRAM.ADDRESS_RANGE $mem]
```

由用户确认并执行Program Configuration Memory Device。禁止整片擦除，保留参数区`0x3E0000–0x3FFFFF`。地址审计只证明镜像覆盖范围，不能替代编程器擦除策略确认。完成后验证Flash启动、匹配LTX、保存记录与活动系数。USB/JTAG握手曾伴随启动异常，相关机制未定；若DONE不保持，先核对实际配置与供电，不把“Flash文件存在”当作启动成功。
