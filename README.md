# NUEDC-2026-G-Artix7-Basys3

第一阶段采集及时域计算 RTL 已放入 `sources/rtl`；Vivado IP 创建/配置脚本见 `scripts/setup_capture_calc.tcl`，接口、定点位宽和 GUI 参数说明见 [`docs/CAPTURE_CALC.md`](docs/CAPTURE_CALC.md)。

第二阶段 FFT、谱峰搜索和 UART 串口屏 RTL/IP 配置见 [`docs/FFT_UART.md`](docs/FFT_UART.md)；自动配置脚本为 `scripts/setup_fft_uart.tcl`，综合检查脚本为 `scripts/synth_check_fft_uart.tcl`。
