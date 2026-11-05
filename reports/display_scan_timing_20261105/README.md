# 波形Amax扫描时序修订

2026-11-05。用户手动运行的P2实现报告为21:58:55；原始报告见[timing_summary_before.rpt](timing_summary_before.rpt)。

| 指标 | 修订前实现 |
| --- | --- |
| WNS / TNS | −0.409 / −1.364 ns |
| setup违例端点 | 4 |
| WHS / THS | +0.021 / 0 ns |
| LUT / BRAM / DSP | 19987/20800、48.5/50、90/90（placed报告） |

4条setup违例均从时域BRAM `mem_hmi_reg_0` 到显示波形模块 `u_wave` 的plot_valid和state寄存器。最差路径数据延迟10.320 ns、13级逻辑，包含6个CARRY4，顺序经过有符号取绝对值、最大值比较/选择和状态判断。它们不是Flash SPI接口违例。

`Display_Wave_Renderer.v`新增SCAN_ABS状态和17位scan_absolute寄存器：

```text
原先：BRAM请求 → BRAM输出 → 取绝对值+比较最大值+状态判断
现在：BRAM请求 → BRAM输出/取绝对值并寄存 → 比较最大值+状态判断
```

每个采样扫描增加1拍，8192点共增加81.92 µs（100 MHz），不增加BRAM或乘法器。17位绝对值保留−32768对应的32768，最终Amax仍为16位unsigned。BRAM请求数量、采样地址、输出像素、幅值缩放和AXI/UART协议不变。没有增加false path、多周期例外或降低算法时钟。

验证入口：`run_display_prepare_sim.ps1`（3个尺寸/边界配置）、`run_display_alignment_sim.ps1`、`run_display_bandlimited_sim.ps1`（2个顶层）、`run_display_hmi_sim.ps1`（6个顶层）。覆盖signed满量程、Amax、逐像素黄金结果、1/3周期、非整频点、谐波、背压、无效帧及UART命令。

本轮4组脚本、共12个仿真顶层全部PASS。原有黄金结果无需修改，−32768边界和BRAM请求数检查均通过。本地完整日志位于`test_results/display_*_sim/`；没有新增仅镜像实现的测试。

源码修订后的正WNS必须由下一次用户手动综合/实现报告确认。11月5日21:59:58磁盘bit对应违例实现，不能作为修复后的产物。该轮操作没有运行综合、布局布线或烧写。
