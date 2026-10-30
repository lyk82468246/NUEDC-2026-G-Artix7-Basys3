# 新屏幕spec适配回归（2026-10-30）

适配说明：[动态us刻度、FFT中点及0起点谱图](../../docs/screen_spec_alignment_20261030.md)。没有IP生成、综合、实现、bit生成、烧写或硬件访问。原09:06的正WNS并非本次源码的时序结果。

| 日志 | 结果 |
| --- | --- |
| hmi.log | 3组XSim顶层通过：短帧、8192点/240像素、Y翻转/稀疏页策略。各17批完整UART事务及1批复位中断。检查100k/10.5k/500k/2MHz格式边界、1/3周期时间、无信号/未标定、半量程49.5uV舍入、全部文本/像素/FF、page顺序、同帧bank、HOLD及STOP后释放 |
| prepare.log | 3组准备模块顶层通过：240×160、200×128、17×256，独立数学对照、边界/背压/复位 |
| top.log | 2组快照/真实板级端口顶层通过，覆盖VIO开关、新旧HMI、校准默认值及采集许可保护；厂商DSP IP黑盒 |
| host.log | 116项离线主机/工程注册/仪器mock回归通过，无实际设备访问 |

复现入口：`scripts/run_display_hmi_sim.ps1`、`scripts/run_display_prepare_sim.ps1`、`scripts/run_measurement_debug_sim.ps1`与主机unittest discover。串口使用缩放的每bit10拍加速，生产仍为100MHz/115200。模拟输入精度、实屏方向/闪动/响应和新资源/时序均待后续手动构建及实测。
