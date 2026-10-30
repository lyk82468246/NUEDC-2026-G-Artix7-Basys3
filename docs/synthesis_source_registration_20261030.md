# 11:53综合失败：GUI源文件列表未同步

实际日志`G_FPGA.runs/synth_1/runme.log`的首个错误为：

```text
[Synth 8-439] module 'Display_Fundamental_Aligner' not found
```

该轮自动生成的综合脚本未包含Display_Fundamental_Aligner.v及Display_Sine_ROM.v。
11:53失败后的XPR也丢失了前次提交登记的这两个文件；此前Vivado窗口一直保持打开，
现象与GUI内存中的旧文件列表覆盖外部更新的XPR一致。源文件本身在磁盘上存在。

此次已恢复磁盘XPR；注册脚本增加全路径预检及逐文件REGISTERED回读。
当前窗口的内存状态仍需使用以下命令更新，否则再次点击综合仍会使用旧列表：

```tcl
source {C:/Users/Joe/Documents/Verilog/G_FPGA/scripts/setup_display_prepare.tcl}
```

在Vivado Tcl Console执行，确认9条REGISTERED均出现，特别是：

```text
REGISTERED: Display_Sine_ROM (synthesis / implementation / simulation)
REGISTERED: Display_Fundamental_Aligner (synthesis / implementation / simulation)
```

随后用户手动重新综合。也可关闭当前工程再重新打开更新后的XPR，但不要让尚未同步的旧窗口再次保存覆盖它。
本轮电脑操作工具未获准控制Vivado，未替用户执行上述GUI命令，也未启动综合。

日志还有随后出现的`Synth 8-525`（分段选择位宽）及上层模块失败；先补齐模块定义，再看新日志，
目前不把这些后续错误认定为独立RTL问题，也不宣称重新综合已通过。
注册脚本仅改变源文件登记及UsedIn属性，不执行综合、IP生成或下载。
