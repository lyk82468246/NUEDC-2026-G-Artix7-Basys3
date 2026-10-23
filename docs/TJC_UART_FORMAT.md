# TJC3224T128_011 双页面串口显示协议

本文档规定本工程中 FPGA 到淘晶驰 TJC 串口屏的单向通信格式。

本文档同时说明双页面目标协议和当前 RTL 的基线格式。`wave` 页面显示时域波形，`fft` 页面显示频谱；页面切换由 FPGA 发送 `page` 命令完成，不使用触摸回传。当前仓库实现仍按 README 中的基线发送 `t0..t3`、一个时域曲线和内部数字量；`tUpp/tUrms/tF1/tA1..tA3` 以及 FFT 页面属于后续扩展接口，完成 RTL 扩展前不能作为已验收功能。

## 1. 设计边界

- FPGA 只使用 `uart_tx`，屏幕 TX 不接 FPGA，工程不实现 UART RX。
- 不使用触摸事件、按键回传、屏幕 ACK 或屏幕变量读取。
- 页面、控件、字体和背景图在 USART HMI 工程中预先创建并下载到屏幕。
- FPGA 运行时只修改已有控件的属性，发送文本、清除曲线和增加曲线点。
- 时域波形和 FFT 频谱分别放在两个竖屏页面，页面名约定为 `wave` 和 `fft`。
- FPGA 只发送 `page wave`、`page fft` 等页面切换命令，不接收触摸事件。

## 2. 串口参数

| 项目 | 设置 |
|---|---|
| 波特率 | 115200 bit/s |
| 数据位 | 8 |
| 校验 | 无 |
| 停止位 | 1 |
| 电平 | 3.3 V TTL，确认屏幕接口电平后再连接 |
| 方向 | Basys 3 `JA1/J1 uart_tx` → 屏幕 RX |

每条命令由 ASCII 命令正文和三个二进制结束字节组成：

```text
[ASCII 字节] 0xFF 0xFF 0xFF
```

不能发送回车、换行，也不能把 `FF` 写成可打印字符。字符串属性必须使用双引号。

示例 `tUpp.txt="125mV"` 的实际字节为：

```text
74 55 70 70 2E 74 78 74 3D 22 31 32 35 6D 56 22 FF FF FF
```

## 3. 双页面控件约定

USART HMI 工程创建两个运行页面：`wave` 和 `fft`。如果屏幕原始分辨率为 320×240，竖屏使用时按 240×320 组织。

```text
wave 页面：
┌────────────────────────┐
│      时域波形 wave      │
│      组件 ID = 1       │
│                        │
│  Y 轴：+Upp/2, 0, -Upp/2│
│  X 轴：0T ～ 1T/3T      │
├────────────────────────┤
│ Upp   tUpp   Urms tUrms│
│ f1    tF1    span tSpan │
└────────────────────────┘

fft 页面：
┌────────────────────────┐
│       FFT 频谱          │
│      组件 ID = 1       │
│                        │
│  Y 轴：0 ～ max mV      │
│  X 轴：10 ～ 500 kHz    │
├────────────────────────┤
│ f1/A1     f2/A2         │
│ f3/A3     返回 wave     │
└────────────────────────┘
```

控件和 ID 必须固定，FPGA 不读取屏幕上的控件信息：

| 控件 | 类型 | 约定 |
|---|---|---|
| `tUpp` | 文本 | 峰峰值，显示 mV |
| `tUrms` | 文本 | 真有效值，显示 mV |
| `tF1` | 文本 | 基频，显示 Hz 或 kHz |
| `tA1` | 文本 | 第 1 个频谱分量幅值，显示 mV |
| `tA2` | 文本 | 第 2 个频谱分量幅值，显示 mV |
| `tA3` | 文本 | 第 3 个频谱分量幅值，显示 mV |
| `wave` | 波形 | `wave` 页面，组件 ID `1`，通道 `0` |
| `spectrum` | 波形 | `fft` 页面，组件 ID `1`，通道 `0` |

如果编辑器分配的组件 ID 不同，必须同步修改 RTL 中的 `cle` 和 `add` 命令。不要依赖控件名称推断 ID。

### 3.1 两个页面的坐标显示

TJC 波形控件接收的 `add id,channel,Y` 只有纵坐标，横坐标由点的发送顺序隐含表示。因此坐标轴、刻度和单位必须在 HMI 工程中用静态文本/直线控件预先画出；FPGA 不发送坐标轴绘图命令。

时域 `wave` 区域建议显示：

- 横轴：`t`，右下角标注 `1T / 3T`。发送 1 周期或 3 周期时，横轴标注随当前模式在 HMI 工程中预留两个文本位置；若不增加 RX，可由 FPGA 同时更新 `tWaveSpan.txt="1T"` 或 `"3T"`。
- 纵轴：中心线为 `0`，上、下端分别标注 `+Upp/2`、`-Upp/2`。中心线对应串口 Y=`128`。
- 正样本映射到屏幕上方：`Y = 128 - round(abs(sample)/Vpp*255)`，结果限制在 `0..255`。
- 负样本映射到屏幕下方：`Y = 128 + round(abs(sample)/Vpp*255)`，结果限制在 `0..255`。

上述`Vpp`归一化与`±Upp/2`标签仅适用于正负峰对称的波形，不能直接用于所有组合信号。P4实现必须改用`Amax=max(abs(min_sample),abs(max_sample))`作为零中心的纵轴满量程，并标注`±Amax`；否则非对称组合信号会截峰。256坐标时可用`Y=128-round(sample*255/(2*Amax))`并限幅；Amax为0需单独处理。实际绘图区不足256高时还须按实际高度重新缩放，不能只靠8位截断。当前基线RTL未完成这一扩展。

建议增加静态控件 `labWaveYTop`、`labWaveY0`、`labWaveYBot`、`labWaveX`，以及一个可由 FPGA 更新的 `tWaveSpan`。若不需要实时显示 1T/3T 标签，`tWaveSpan` 可以改成固定静态文字。

`fft` 页面的 `spectrum` 区域建议显示：

- 横轴：正频率轴，左端标 `10kHz`，右端标 `500kHz`；FFT 分辨率为 `500Hz`，点序号 `p` 映射到 `f = 10kHz + p*Δf`。
- 纵轴：幅值 `mV`，底线为 `0`，顶部使用当前帧最大分量或固定满量程。每个频谱点先归一化为 `Y=0..255` 后发送。
- 频谱峰值的实际频率和幅值不靠坐标读数，而是通过 `tF1/tA1`、`tF2/tA2`、`tF3/tA3` 文本控件显示。

建议增加静态控件 `labFftYTop`、`labFftY0`、`labFftXLeft`、`labFftXRight`。如果纵轴采用动态满量程，再增加 `tFftScale.txt="<max_mV>mV"`，每帧先更新刻度再发送频谱点。两个页面各自维护坐标标签，不要把 wave 页的刻度控件名称复用到 fft 页。

### 3.2 预绘制坐标的实时更新

坐标轴的线条和网格可以在两个 HMI 页面中固定绘制；需要随测量结果变化的数字、单位和范围必须创建成文本控件。FPGA 通过串口修改当前页面文本控件的 `.txt` 属性，屏幕会立即刷新，不需要 UART RX，也不需要触摸事件。

建议分别在对应的 `wave` / `fft` 页面预先创建以下文本控件，并设置透明背景、合适字体和足够宽度：

```text
tWaveYTop     // 例如 "+125mV"
tWaveY0       // 固定显示 "0"
tWaveYBot     // 例如 "-125mV"
tWaveSpan     // "1T" 或 "3T"
tFftYTop      // 例如 "80mV"
tFftY0        // 固定显示 "0"
tFftXLeft     // "10kHz"
tFftXRight    // "500kHz"
```

其中 `tWave*` 控件属于 `wave` 页面，`tFft*` 控件属于 `fft` 页面；两个页面可以使用相同的控件名，但 FPGA 必须先切换到对应页面再赋值。

每个文本控件都用普通串口赋值更新：

```text
tWaveYTop.txt="+125mV"  FF FF FF
tWaveYBot.txt="-125mV"  FF FF FF
tWaveSpan.txt="3T"       FF FF FF
tFftYTop.txt="80mV"      FF FF FF
```

FPGA 应在发送对应曲线之前先切换到对应页面、更新本帧坐标标签，再发送 `cle` 和 `add`：

```text
page wave
更新时域刻度文本
cle 1,0
发送 wave 点

page fft
更新频域刻度文本
cle 1,0
发送 spectrum 点
```

如果坐标标签使用图片、静态背景或线条控件，串口修改 `.txt` 不会改变它们。要动态改变数值，必须在 HMI 编辑器中另外放置文本控件。坐标轴位置本身建议固定，FPGA 只改变刻度文字和曲线点；这样不会因为串口刷新造成旧线条残留或布局抖动。

## 4. 文本更新命令

页面切换命令使用页面名：

```text
page wave
page fft
```

切换页面后，只给当前页面的控件赋值。两个页面的波形控件都使用组件 ID `1`；组件 ID 是页面内编号，不能在 `fft` 页面发送 `add 2,0,Y`。

FPGA 发送以下格式：

```text
tUpp.txt="<Upp_mV>mV"
tUrms.txt="<Urms_mV>mV"
tF1.txt="<f1_Hz>Hz"
tA1.txt="<A1_mV>mV"
tA2.txt="<A2_mV>mV"
tA3.txt="<A3_mV>mV"
```

例如：

```text
tUpp.txt="126mV"  FF FF FF
tUrms.txt="44mV"   FF FF FF
tF1.txt="10500Hz" FF FF FF
tA1.txt="80mV"    FF FF FF
tA2.txt="24mV"    FF FF FF
tA3.txt="11mV"    FF FF FF
```

数值必须是已经完成量程和幅值校准的结果。FFT 原始 bin 幅值不能直接作为题目要求的 mV 结果。

## 5. 时域波形格式

每次新的测量帧开始发送：

```text
page wave
cle 1,0
```

随后发送若干个波形点：

```text
add 1,0,<Y>
```

其中 `<Y>` 是十进制坐标，不是ADC原始有符号数；0～255只适用于对应的纵向绘图区。发送点数必须匹配实际绘图区宽度，400点仅作旧方案示例，不得向不足400像素宽的控件硬发400点而使前部滚走。当前新顶层暂设240点，仍待实屏尺寸确认。现有`HMI_UART_Ctrl`有1/3周期选择和相邻样本插值，但分数周期跨度、非对称波形纵轴和实际尺寸适配仍待扩展。

示例：

```text
cle 1,0 FF FF FF
add 1,0,127 FF FF FF
add 1,0,151 FF FF FF
add 1,0,178 FF FF FF
```

本协议不发送触摸相关命令；页面切换只由 FPGA 发送 `page wave` 或 `page fft` 完成。

## 6. FFT 频谱格式

每次新的 FFT 结果开始发送：

```text
page fft
cle 1,0
```

再发送抽样后的频谱幅值：

```text
add 1,0,<Y>
```

`<Y>` 同样限制为 `0..255`。频谱横坐标由曲线点顺序表示正频率轴；FPGA 可以从 10 kHz 到 500 kHz 的有效范围抽取 100～200 个点。题目只要求定性频谱图，不需要把全部 4096 个 FFT bin 发送到屏幕。

频谱分量的精确数值通过文本控件发送：

```text
tA1.txt="<A1_mV>mV"
tA2.txt="<A2_mV>mV"
tA3.txt="<A3_mV>mV"
```

建议 `A1`、`A2`、`A3` 按幅值从大到小或按频率从低到高固定一种顺序，并在设计报告中说明。对于题目给出的基波、三次谐波、四次谐波示例，应按频率顺序显示 `10.5 kHz`、`31.5 kHz`、`42.0 kHz`。

## 7. 一帧发送顺序

为了保证同一组测量结果不会混在不同帧中，FPGA 在获得时域结果和 FFT 峰值结果后，锁存一份 active snapshot，再按以下顺序发送：

```text
1. page wave
2. 更新 wave 页文本和坐标刻度
3. cle 1,0
4. 发送 wave 页的全部 add 命令
5. page fft
6. 更新 fft 页文本和坐标刻度
7. cle 1,0
8. 发送 fft 页的全部 add 命令
9. 本帧结束，释放采集保持状态
```

每个字节只能在 UART 空闲时送入 `UART_Tx`。消息 FSM 不得覆盖正在发送的字节；曲线发送期间应保持本帧 BRAM 快照不变。

115200 bit/s、8N1时，一个字节约86.8us。以400+150点、每条12～14字节计算，仅曲线线缆传输约0.57～0.67秒，另有文本、算法、切页和屏幕执行时间；这只是预算，不能由此宣布两秒可见响应已验收。不能按ADC每个采样点实时刷新屏幕。

## 8. 与当前工程的对应关系

当前仓库基线与本文目标协议的差异如下：

| 项目 | 当前 RTL 基线 | 本文目标协议 |
|---|---|---|
| 文本控件 | `t0`、`t1`、`t2`、`t3` | `tUpp`、`tUrms`、`tF1`、`tA1`、`tA2`、`tA3` |
| 曲线 | `wave` 页 ID 1，只有时域波形 | `wave` 页 ID 1 + `fft` 页 ID 1 |
| 幅值 | 内部数字量，尚未完成输入端 mV 标定 | 校准后的 mV |
| 频谱峰值 | 只输出最大峰 `f1/amp_f1` | 输出至少三个分量及其频率/幅值 |
| 1/3 周期 | `BtnU` 在 FPGA 内部切换 | 仍由 FPGA 输入控制，不使用屏幕触摸 |

要采用本文目标控件名，必须同步修改 `sources/rtl/HMI_UART_Ctrl.v` 的文本前缀、增加 FFT 曲线发送状态，并扩展峰值搜索输出。否则 HMI 工程应按当前基线创建 `t0..t3` 和 ID 1 波形控件。

当前 `BtnU` 仍可作为 FPGA 内部的 1 周期/3 周期选择输入；它不是屏幕触摸功能。`G_FPGA_Top` 不需要 UART RX 端口，也不需要触摸事件解析。

## 9. 上电和调试

1. 采用目标协议时先将双页面HMI工程下载到屏幕；当前基线RTL仍需旧控件，不能混用。
2. 确认屏幕串口设置为 115200、8N1。
3. 用 USB-TTL 只连接一个发送源；按当前 RTL 基线测试 `t0.txt="TEST"`，切换到目标协议后再测试 `tUpp.txt="TEST"`。
4. 确认 `cle` 和 `add` 的组件 ID 与 HMI 工程一致。
5. 最后连接 `Basys3 JA1/J1 uart_tx` 到屏幕 RX，并共地。

故障排查优先检查：5 V 供电、共地、TX→RX 方向、115200 波特率、控件名称、组件 ID，以及每条命令末尾的三个二进制 `0xFF`。

## 10. 单音信号串口示例

下面示例模拟一个单音信号：

- `Upp = 250mV`
- `Urms = 88mV`
- `f1 = 100000Hz`
- 先在 `wave` 页面显示 1 个周期
- 再在同一 `wave` 页面显示 3 个周期，并更新横轴刻度
- 最后切换到 `fft` 页面，显示 100kHz 附近的单根频谱线

示例只列出少量 `add` 点以便检查协议；实际工程应继续发送完整的 400 个 wave 点和频谱抽样点。

### 10.1 文本命令

每一行都是一条独立命令，实际发送时在行尾附加三个二进制 `0xFF`：

```text
# wave：1 个周期
page wave
tWaveYTop.txt="+125mV"
tWaveY0.txt="0"
tWaveYBot.txt="-125mV"
tWaveSpan.txt="1T"
tUpp.txt="250mV"
tUrms.txt="88mV"
tF1.txt="100000Hz"
cle 1,0
add 1,0,128
add 1,0,64
add 1,0,128
add 1,0,192

# wave：3 个周期，更新自适应横轴
tWaveSpan.txt="3T"
tWaveXLeft.txt="0T"
tWaveXRight.txt="3T"
cle 1,0
add 1,0,128
add 1,0,64
add 1,0,128
add 1,0,192

# 切换 fft 页面
page fft
tFftYTop.txt="125mV"
tFftY0.txt="0"
tFftXLeft.txt="10kHz"
tFftXRight.txt="500kHz"
tA1.txt="125mV"
cle 1,0
add 1,0,0
add 1,0,0
add 1,0,255
add 1,0,0
add 1,0,0
```

`wave` 页的纵轴在这个例子中固定为 `+125mV / 0 / -125mV`；3 周期显示只改变横轴 `0T..3T` 和重新发送的曲线点。若下一帧的峰峰值改变，FPGA 应重新计算并发送 `tWaveYTop`、`tWaveYBot`。

### 10.2 对应十六进制字节

以下十六进制字节与上面的命令顺序一致。`FF FF FF` 是三个真实的结束字节，不是字符串：

```text
# page wave
70 61 67 65 20 77 61 76 65 FF FF FF
# tWaveYTop.txt="+125mV"
74 57 61 76 65 59 54 6F 70 2E 74 78 74 3D 22 2B 31 32 35 6D 56 22 FF FF FF
# tWaveY0.txt="0"
74 57 61 76 65 59 30 2E 74 78 74 3D 22 30 22 FF FF FF
# tWaveYBot.txt="-125mV"
74 57 61 76 65 59 42 6F 74 2E 74 78 74 3D 22 2D 31 32 35 6D 56 22 FF FF FF
# tWaveSpan.txt="1T"
74 57 61 76 65 53 70 61 6E 2E 74 78 74 3D 22 31 54 22 FF FF FF
# tUpp.txt="250mV"
74 55 70 70 2E 74 78 74 3D 22 32 35 30 6D 56 22 FF FF FF
# tUrms.txt="88mV"
74 55 72 6D 73 2E 74 78 74 3D 22 38 38 6D 56 22 FF FF FF
# tF1.txt="100000Hz"
74 46 31 2E 74 78 74 3D 22 31 30 30 30 30 30 48 7A 22 FF FF FF
# cle 1,0
63 6C 65 20 31 2C 30 FF FF FF
# add 1,0,128 / 64 / 128 / 192
61 64 64 20 31 2C 30 2C 31 32 38 FF FF FF
61 64 64 20 31 2C 30 2C 36 34 FF FF FF
61 64 64 20 31 2C 30 2C 31 32 38 FF FF FF
61 64 64 20 31 2C 30 2C 31 39 32 FF FF FF

# 3 周期坐标更新
74 57 61 76 65 53 70 61 6E 2E 74 78 74 3D 22 33 54 22 FF FF FF
74 57 61 76 65 58 4C 65 66 74 2E 74 78 74 3D 22 30 54 22 FF FF FF
74 57 61 76 65 58 52 69 67 68 74 2E 74 78 74 3D 22 33 54 22 FF FF FF

# page fft
70 61 67 65 20 66 66 74 FF FF FF
# tFftYTop/tFftY0/tFftXLeft/tFftXRight/tA1
74 46 66 74 59 54 6F 70 2E 74 78 74 3D 22 31 32 35 6D 56 22 FF FF FF
74 46 66 74 59 30 2E 74 78 74 3D 22 30 22 FF FF FF
74 46 66 74 58 4C 65 66 74 2E 74 78 74 3D 22 31 30 6B 48 7A 22 FF FF FF
74 46 66 74 58 52 69 67 68 74 2E 74 78 74 3D 22 35 30 30 6B 48 7A 22 FF FF FF
74 41 31 2E 74 78 74 3D 22 31 32 35 6D 56 22 FF FF FF
# cle 1,0 and FFT peak sample
63 6C 65 20 31 2C 30 FF FF FF
61 64 64 20 31 2C 30 2C 30 FF FF FF
61 64 64 20 31 2C 30 2C 30 FF FF FF
61 64 64 20 31 2C 30 2C 32 35 35 FF FF FF
61 64 64 20 31 2C 30 2C 30 FF FF FF
61 64 64 20 31 2C 30 2C 30 FF FF FF
```
