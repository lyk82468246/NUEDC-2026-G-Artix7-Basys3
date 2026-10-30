# 屏幕串口协议

## 1. 串口格式

- 115200 bit/s，8N1。
- 发送端 TX 接屏幕 RX，两端共地。
- 每条命令为 ASCII 正文，末尾追加三个二进制字节 `FF FF FF`。
- 不发送回车、换行或可打印字符串 `\xff`。
- 文本值使用英文双引号。

```text
命令：tUpp.txt="250mV"
字节：74 55 70 70 2E 74 78 74 3D 22 32 35 30 6D 56 22 FF FF FF
```

## 2. 页面与波形控件

| 页面 | 用途 | 波形组件 ID | 通道 | 宽×高 |
|---|---|---|---|---|
| `wave` | 时域波形 | 1 | 0 | 240×160 |
| `fft` | 频谱 | 1 | 0 | 240×160 |

- 每组曲线发送 **240 个点**，横向位置依次为 `0..239`。
- `add` 的纵坐标 Y 必须为整数 **`0..159`**。
- 时域零点为 Y=80；频谱基线为 Y=0。
- 坐标刻度文本放在波形控件矩形之外。
- 页面、控件名称和 ID 必须与下表一致。

## 3. 文本控件

### wave 页面

| 控件 | 含义 | 1T 示例 | 3T 示例 |
|---|---|---|---|
| `tWaveYTop` | 纵轴上端 | `+125mV` | `+125mV` |
| `tWaveY0` | 纵轴零点 | `0` | `0` |
| `tWaveYBot` | 纵轴下端 | `-125mV` | `-125mV` |
| `tWaveXLeft` | 横轴左端 | `0us` | `0us` |
| `tWaveXMid` | 横轴中点 | `5us` | `15us` |
| `tWaveXRight` | 横轴右端 | `10us` | `30us` |
| `tWaveSpan` | 周期数 | `1T` | `3T` |
| `tUpp` | 峰峰值 | `250mV` | `250mV` |
| `tUrms` | 有效值 | `88.4mV` | `88.4mV` |
| `tF1` | 频率 | `100000Hz` | `100000Hz` |

### fft 页面

| 控件 | 含义 | 示例 |
|---|---|---|
| `tFftYTop` | 纵轴上端 | `150mV` |
| `tFftYMid` | 纵轴中点 | `75mV` |
| `tFftY0` | 纵轴零点 | `0` |
| `tFftXLeft` | 横轴左端 | `0kHz` |
| `tFftXMid` | 横轴中点 | `100kHz` |
| `tFftXRight` | 横轴右端 | `200kHz` |
| `tF1` / `tA1` | 第一分量频率/幅值 | `100000Hz` / `125mV` |
| `tF2` / `tA2` | 第二分量频率/幅值 | `--` / `--` |
| `tF3` / `tA3` | 第三分量频率/幅值 | `--` / `--` |

## 4. 指令与发送顺序

| 指令 | 作用 |
|---|---|
| `page wave` | 切换到时域页 |
| `page fft` | 切换到频谱页 |
| `控件名.txt="内容"` | 更新当前页文本 |
| `cle 1,0` | 清除当前页波形控件通道 0 |
| `add 1,0,Y` | 追加一个 Y=`0..159` 的曲线点 |

每组严格按以下顺序发送：

1. 切换页面，等待屏幕完成切页。
2. 更新当前页全部测量文本和坐标刻度。
3. 发送 `cle 1,0`。
4. 顺序发送 240 条 `add 1,0,Y`。

每条指令都必须附带三个 `0xFF`。`add` 不包含 X 参数，点的发送顺序决定横向位置。

## 5. 完整示例

示例信号为 100 kHz、250 mV 峰峰值正弦波。以下文件包含全部命令及 240 个曲线点：

| 示例 | ASCII 命令文件 | HEX 字节文件 |
|---|---|---|
| 时域 1T | [wave_1T_text.txt](tjc_serial_examples/wave_1T_text.txt) | [wave_1T_hex.txt](tjc_serial_examples/wave_1T_hex.txt) |
| 时域 3T | [wave_3T_text.txt](tjc_serial_examples/wave_3T_text.txt) | [wave_3T_hex.txt](tjc_serial_examples/wave_3T_hex.txt) |
| 频谱 | [fft_text.txt](tjc_serial_examples/fft_text.txt) | [fft_hex.txt](tjc_serial_examples/fft_hex.txt) |

组合文件按 1T → 3T → FFT 顺序发送：

- [all_text.txt](tjc_serial_examples/all_text.txt)：758 条完整命令，包含 720 个曲线点。
- [all_uart.bin](tjc_serial_examples/all_uart.bin)：带结束符的完整串口字节，可直接以二进制发送。

| 格式 | 发送方法 |
|---|---|
| ASCII TXT | 每行去掉换行，发送 ASCII 正文，再追加 `FF FF FF` |
| HEX TXT | 按十六进制解码发送，文件中已含结束符 |
| BIN | 原样发送，不添加换行或结束符 |

观察单个画面时发送对应单组文件。连续发送组合文件后，屏幕停留在 `fft` 页面。调试时屏幕 RX 只连接一个 TX 来源。
