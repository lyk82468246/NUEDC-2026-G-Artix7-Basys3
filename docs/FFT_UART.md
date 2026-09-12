# Step 2：FFT、谱峰搜索与 UART 串口屏

本阶段把第一阶段的 `Capture_Calc_Subsystem` 扩展为：

```text
AFE_Capture -> BRAM_TimeDomain
                    |-> Time_Domain_Calc
                    |-> FFT_Processor -> BRAM_FreqDomain -> Peak_Search
                    `-> HMI_UART_Ctrl -> UART_Tx
```

当前 `Capture_Calc_Subsystem` 是算法联调顶层，端口仍然是 `adc_clk`、`calc_clk`、ADC 并行数据、测量结果和 `uart_tx`。100 MHz/4.096 MHz 的 MMCM、Basys 3 引脚 XDC 以及 AD9226 电气时序留到板级顶层接入。

## 新增文件

- `sources/rtl/FFT_Processor.v`：同步读时域 BRAM、平顶窗、XFFT、CORDIC 幅值、频域 BRAM 写入。
- `sources/rtl/Peak_Search.v`：扫描 bin 10..4000，输出 `max_index`、`f1_hz` 和 `amp_f1`。
- `sources/rtl/HMI_UART_Ctrl.v`：四路数值格式化、UART 消息 FSM、400 点波形抽样。
- `sources/rtl/BIN2BCD.v`：通用 Shift-and-Add-3/Double-Dabble 转换器。
- `sources/rtl/FlatTop_Window_ROM.v`：Block Memory Generator ROM 封装。
- `sources/rtl/BRAM_FreqDomain.v`：4096 x 32-bit 幅值缓存。
- `scripts/generate_flattop.py`：生成 `sources/coeffs/flat_top_window_8192.coe`。
- `scripts/setup_fft_uart.tcl`：配置并生成 XFFT、Translate CORDIC 和 ROM IP。
- `scripts/synth_check_fft_uart.tcl`：综合 `Capture_Calc_Subsystem` 并输出报告。

## 固定点与 IP 配置

### Flat-top ROM

`generate_flattop.py` 使用五项标准平顶窗：

```text
w[n] = A0 - A1 cos(theta) + A2 cos(2 theta)
       - A3 cos(3 theta) + A4 cos(4 theta)
theta = 2 pi n / (N - 1)
```

系数写成 signed Q1.15，深度 8192，Vivado ROM 为 `Single_Port_ROM / Native / 8192 x 16 / ENA / registered output`。ROM 与时域 BRAM 在同一个 `calc_clk` 上同步读，所以 `FFT_Processor` 使用 `READ_REQUEST -> PREPARE` 两拍配对样本和窗系数。

### XFFT `xfft_8192`

`setup_fft_uart.tcl` 的核心配置如下：

| 参数 | 值 |
|---|---|
| Transform Length | 8192 |
| Architecture | Radix-4 Burst I/O |
| Data Format | Fixed Point |
| Scaling | Unscaled |
| Output Ordering | Natural Order |
| Throttle | Non-Realtime |
| Input Width | 16 bit |
| Runtime NFFT | Disabled |

在 Vivado 2025.2、`xc7a35tcpg236-1` 上，实际生成的 AXI 端口为：

- `s_axis_config_tdata[7:0]`：固定长度、正变换配置为 `8'h01`。
- `s_axis_data_tdata[31:0]`：低 16 bit 是实部，虚部为 0。
- `m_axis_data_tdata[63:0]`：低 32-bit 字段为实部，高 32-bit 字段为虚部；每个字段的有效 FFT 分量为 30 bit，即 `I[29:0]` 与 `Q[61:32]`。

未缩放输出的有效宽度按 `16 + log2(8192) + 1 = 30` bit 派生。选择 Unscaled 是为了不引入每级 scaling schedule；在当前 16-bit 输入范围内 30-bit 分量可以容纳累加结果，后续幅值标定集中由 `MAG_SCALE_FACTOR` 处理。

XFFT 配置、输入和输出均遵守 AXI4-Stream：`TVALID=1` 后，数据和 `TLAST` 在 `TREADY=0` 时保持不变；只有 `TVALID && TREADY` 才推进输入计数。FFT 输出侧有一个寄存器级 skid buffer，防止 CORDIC 反压时丢 bin。

### Translate CORDIC `cordic_translate_mag`

配置为 `Translate / Parallel / Maximum / SignedFraction / Input 30 / Output 31 / Coarse Rotation / Embedded Multiplier Compensation / Blocking`。

`SignedFraction` 的 AXI 数据按两个 32-bit 对齐字段打包：低字段是 X，高字段是 Y；有效输入各占低 30 bit，输出幅值取 `m_axis_dout_tdata[30:0]`。FFT 的 30-bit 分量送入前算术右移 1，使最坏情况落在 SignedFraction 的安全范围内；CORDIC 输出的 31-bit 原始值再直接写入 32-bit `BRAM_FreqDomain`。

### BRAM 组织

时域数据需要被统计、FFT 和 HMI 三个同步读口独立读取，因此 `BRAM_TimeDomain.v` 保留一个 ADC 写口并复制三份 `8192 x 16` 存储阵列。这样 HMI 的 UART 慢速发送不会阻塞 FFT 或时域计算。频域 BRAM 仅写入 bin 0..4095。

## Peak Search

收到 `freq_frame_done_toggle` 后，FSM 对频域 BRAM 的同步读延迟使用 `READ_REQUEST -> PROCESS` 两状态，扫描地址 10..4000（含首尾）。

```text
f1_hz = max_index * 500
amp_f1 = saturate(freq[max_index] * MAG_SCALE_FACTOR)
```

`MAG_SCALE_FACTOR` 默认为 1。平顶窗的 coherent gain、FFT 归一化和 ADC 电压换算需要用实测校准值替换该参数或在此处改成 Q 格式乘法。

## UART 串口屏

`UART_Tx` 为 8-N-1，100 MHz 下 `CLKS_PER_BIT = floor(100000000/115200) = 868`。HMI 每次等待时域结果和峰值结果都到齐后，发送四条文本控件命令：

```text
t0.txt="<Vpp>" FF FF FF
t1.txt="<Vrms>" FF FF FF
t2.txt="<f1>"  FF FF FF
t3.txt="<amp>" FF FF FF
```

数值由四个并行 `BIN2BCD` 实例产生，ASCII 发送时去掉最高位多余的 0，但全零仍保留一个字符 `0`。

波形部分默认 `DISPLAY_CYCLES=1`、400 点。根据 `f1_index` 计算：

```text
N_cycle = 8192 / f1_index
span    = min(N_cycle * DISPLAY_CYCLES - 1, 8191)
address[p] = floor(p * span / 399)
```

每点先读 HMI 专用 BRAM 口，再用一个 25-cycle restoring divider 计算 `abs(sample) * 255 / Vpp`，映射为 0..255 的 Y，最后发送：

```text
add 1,0,<Y> FF FF FF
```

将 `Capture_Calc_Subsystem` 中的 `DISPLAY_CYCLES` 改为 3 即可请求三周期显示；若三周期超过 8192 点，逻辑会自动截到当前帧范围。

## Windows 操作流程

在工程根目录打开 PowerShell：

```powershell
python scripts/generate_flattop.py

$env:PROCESSOR_ARCHITECTURE = 'AMD64'
$env:XILINX_LOCAL_USER_DATA = 'NO'
& 'C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat' -mode batch -nolog -nojournal -notrace `
    -source 'C:\Users\Joe\Documents\Verilog\G_FPGA\scripts\setup_fft_uart.tcl' `
    -tclargs 'C:\Users\Joe\Documents\Verilog\G_FPGA\G_FPGA.xpr'

& 'C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat' -mode batch -nolog -nojournal -notrace `
    -source 'C:\Users\Joe\Documents\Verilog\G_FPGA\scripts\synth_check_fft_uart.tcl' `
    -tclargs 'C:\Users\Joe\Documents\Verilog\G_FPGA\G_FPGA.xpr'
```

脚本会把 `Capture_Calc_Subsystem` 设为 `sources_1` 的 top，并生成 `reports/fft_uart_utilization.rpt` 与 `reports/fft_uart_timing.rpt`。当前工程的时序报告还没有板级 100 MHz XDC，因此时钟表为空；这不等同于已完成实现时序收敛。

参考： [AMD XFFT PG109](https://docs.amd.com/r/en-US/pg109-xfft)、[AMD CORDIC PG105](https://docs.amd.com/api/khub/documents/NHMqdvRJIfgF8hdbQmLFuA/content)、[AMD Block Memory Generator PG058](https://docs.amd.com/api/khub/documents/EkYkK5QhXgNspmxLeIQMMw/content)。
