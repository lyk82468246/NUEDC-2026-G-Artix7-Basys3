# AFE_Capture / Time_Domain_Calc 使用说明

本阶段工程链路如下：

```text
AD9226(12-bit offset binary)
        |
        v
AFE_Capture --(adc_clk, 4.096 MHz)--> BRAM_TimeDomain
        |                                  |
        +-- frame_done_toggle ------------>+-- Time_Domain_Calc(calc_clk, 建议 100 MHz)
                                               |
                                               +--> Vpp / mean-square / Vrms
```

## 文件

- `sources/rtl/AFE_Capture.v`：ADC 格式转换、FIR 例化、慢速 DC 跟踪、过零触发和 8192 点写入。
- `sources/rtl/Time_Domain_Calc.v`：BRAM 遍历、signed max/min、平方累加、CORDIC 开方。
- `sources/rtl/BRAM_TimeDomain.v`：8192 x 16-bit 双时钟时域缓存；当前为一个 ADC 写口加三份独立同步读副本，分别服务时域统计、FFT 和 HMI。
- `sources/rtl/Capture_Calc_Subsystem.v`：本阶段临时联调封装，不含 MMCM 和板级引脚。
- `sources/coeffs/fir_lp_600k_95t.coe`：95 个实数 FIR 系数，按 Q1.15 量化。
- `scripts/setup_capture_calc.tcl`：加入 RTL、创建/配置 IP、生成 IP 输出并设置临时 top。

## 运行脚本

在 Vivado Tcl Console 中：

```tcl
source scripts/setup_capture_calc.tcl
```

也可以在工程目录外批处理：

```text
vivado -mode batch -source scripts/setup_capture_calc.tcl -tclargs G_FPGA.xpr
```

脚本默认把 `Capture_Calc_Subsystem` 设为本阶段 top。后续加入真实 Basys 3 顶层后，应把 `sources_1` 的 top 改成实际顶层，并把 `adc_clk`、`calc_clk` 和复位连接到对应时钟/复位模块。

## FIR Compiler GUI 参数

IP 名称：`fir_compiler_lp_600k`，建议使用 FIR Compiler 7.2（若本机版本不同，按同名字段配置）。

| 页面 | 参数 | 值 |
|---|---|---|
| Filter Specification | Filter Type | Single Rate |
| Filter Specification | Coefficient Source | Vector，或加载 `sources/coeffs/fir_lp_600k_95t.coe` |
| Filter Specification | Coefficient Sets / Reload | 1 / False |
| Implementation | Coefficient Sign / Width | Signed / 16 |
| Implementation | Coefficient Fractional Bits | 15 |
| Implementation | Input Data Sign / Width | Signed / 16 |
| Implementation | Input Data Fractional Bits | 0 |
| Implementation | Output Rounding | Truncate LSBs |
| Implementation | Output Width | 16 |
| Implementation | Filter Architecture | Systolic Multiply Accumulate |
| Rate Specification | Input/Output Sample Frequency | 4.096 MHz |
| Rate Specification | Clock Frequency | 4.096 MHz（本 RTL 把 FIR 放在 adc_clk 域） |
| Interface | Number of Channels / Paths | 1 / 1 |
| Interface | Input FIFO | IP 自动决定（本机 Vivado 2025.2 生成值为 True） |
| Interface | Output TREADY | True |
| Interface | TLAST | Not Required |
| Control Signals | ARESETn | True |

系数使用 95-tap Kaiser-windowed low-pass，设计过渡中心约为 750 kHz；Q1.15 量化系数和为 32768。该系数在 600 kHz 附近保持通带，在 900 kHz 以后进入阻带，1 MHz 干扰得到较强抑制。最终仍应在 Vivado FIR Analysis 或离线频响中复核实际系数和量化选项。

FIR 的 AXI4-Stream 连接必须与 `AFE_Capture.v` 一致：

```text
aclk                 = adc_clk
aresetn              = ~rst
s_axis_data_tvalid  = ~rst
s_axis_data_tready  -> fir_s_axis_tready
s_axis_data_tdata   = signed 16-bit ADC sample
m_axis_data_tvalid  -> fir_m_axis_tvalid
m_axis_data_tready  = 1'b1
m_axis_data_tdata   -> signed filtered sample
```

## CORDIC GUI 参数

IP 名称：`cordic_sqrt_rms`，使用 CORDIC v6.0。

| 页面 | 参数 | 值 |
|---|---|---|
| Configuration | Functional Selection | Square Root |
| Configuration | Architectural Configuration | Parallel |
| Configuration | Pipelining Mode | Maximum |
| Configuration | Data Format | Unsigned Integer |
| Configuration | Input Width | 32 |
| Configuration | Output Width | 自动派生 17 bit（AXI TDATA 字节对齐为 24 bit） |
| Configuration | Round Mode | Nearest Even |
| Advanced | Iterations / Precision | 0 / 0（Automatic） |
| Advanced | Coarse Rotation | False（Square Root 不需要） |
| AXI4-Stream | Flow Control | Blocking |
| AXI4-Stream | Output has TREADY | True |
| AXI4-Stream | Cartesian TLAST/TUSER | False / False |
| Control Signals | ARESETn | True |

`Time_Domain_Calc` 对每个样本做 16 x 16 signed 乘法，使用 44-bit 累加器。帧末计算：

```text
mean_square = (sum_square + last_sample_square) >> 13
vrms        = sqrt(mean_square)
```

由于 16-bit signed 样本平方的平均值不超过约 `2^30`，所以用 CORDIC 的 32-bit Unsigned Integer X_IN 足够；平方根结果在 16 bit 内。Square Root 的输出宽度由 IP 自动派生为 17 bit，AXI4-Stream 端口按字节对齐为 24 bit，RTL 取其低 16 bit 作为 `vrms_out`。CORDIC 的 `s_axis_cartesian_tdata` 对 Square Root 只承载 X_IN，代码直接送 32-bit 均方值。

## 端口与时序注意事项

1. `frame_done_toggle` 是 ADC 域的状态翻转，不是跨时钟脉冲；`AFE_Capture` 在最后一个 BRAM 写入提交后一拍才翻转它，`Time_Domain_Calc` 内部再用两级同步器检测变化。
2. BRAM 为同步读，`Time_Domain_Calc` 的 `ST_READ_REQUEST` 和 `ST_PROCESS` 两个状态配合一个读延迟。一次 8192 点遍历需要约 16384 个 `calc_clk` 周期，100 MHz 下约 164 us。
3. AFE 的 ADC offset-binary 中点默认是 2048，并左移 4 位送 FIR。如果 ADC 模块输出 two's complement，应将 `ADC_OFFSET_BINARY=0`。
4. `AFE_Capture` 里有慢速 DC 跟踪器；默认时间常数约 1 ms，低于 10 kHz 测量频率，不应显著衰减被测信号。复位后默认等待 4096 个 FIR 有效样本再允许过零触发，避免启动瞬态形成第一帧。若外部 AFE 已完成精确 AC 耦合，可将 `DC_TRACK_SHIFT` 调大、将 `DC_WARMUP_SAMPLES` 置 0，或在后续版本旁路。
5. 输出 `vpp_out` 是 17 bit，这是为了保留 `+32767 - (-32768) = 65535` 的完整范围；`vrms_out` 是 16 bit。
6. 当前模块在 FIR `s_axis_data_tready` 拉低时不会缓存 ADC 样本。FIR 应配置为单速率、连续吞吐；若综合后吞吐率不足，需要在 ADC 与 FIR 之间增加异步 FIFO。

## 官方 IP 文档

- [AMD FIR Compiler PG149](https://docs.amd.com/r/en-US/pg149-fir-compiler)
- [AMD CORDIC PG105](https://docs.amd.com/api/khub/documents/NHMqdvRJIfgF8hdbQmLFuA/content)
