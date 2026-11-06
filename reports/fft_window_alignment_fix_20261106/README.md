# FFT平顶窗ROM配对：生产RTL修复

2026-11-06。本轮将已经用真实ROM模型确认的使能/延迟缺陷修复到生产`FFT_Processor.v`，不再仅是诊断版本。未启动综合、实现、生成bit、JTAG下载、仪器输出或Flash写入。标定系数及谱峰门限不变。

## 修改

旧顺序READ_REQUEST → PREPARE在单次ENA后读到前一请求的窗系数。现在为：

```text
READ_REQUEST：时域BRAM读样本i；ROM使能，地址i
READ_WAIT：   时域BRAM保持；ROM继续使能，地址仍为i
PREPARE：     锁存样本i和正确系数i
WINDOW_MULT：乘法/移位/饱和，准备AXI数据
SEND：       保持valid/data/last，直到ready握手
```

只是ENA=0的空等拍不能修复，因为当前生成ROM的原语输出寄存器也受使能控制。没有修改IP配置或取消输出寄存器；保留原有DSP输入寄存器。每帧仍只有8192次时域BRAM读取、8192次FFT数据握手；ROM每地址连续使能两次。无背压时，8192点增加8192个算法周期，约81.92µs。不新增DSP、BRAM或页缓存；实际资源与时序仍需用户重新实现确认。

生产修改仅涉及FFT_Processor读状态机和FlatTop_Window_ROM契约注释。新状态不推进地址/样本计数；只有真实FFT输入握手才推进，故背压不会引入重复样本或错位。

## 验证

### 强制背压与旧版反例

入口：`scripts/run_fft_window_backpressure_sim.ps1 -CheckLegacy`。

采用真实生成ROM模型和生产FFT包装器；FFT输入端为专门的协议替身，周期性拉低配置/数据ready，**不计算FFT或产生输出**。三组signed满范围数据（包含−32768、32767及首末地址），每组8192点；组间重置算法但不重置ROM。逐握手检查独立参考乘法/移位结果、虚部0、TLAST和暂停期间包含ready恢复周期的payload稳定性。

结果：24576个golden输入检查通过，98295个强制暂停周期。摘要见[背压结果](forced_backpressure_result.txt)。

同一测试在隔离目录编译63c1688旧FFT、仅重命名模块以免覆盖生产库，首次输入就失败：actual=0、expected=14。源码旧版的样本−32768与错误初值系数0相乘，而正确系数为−14。反例见[旧版预期失败](legacy_negative_control.txt)。脚本把这个精确断言失败视为反例验证成功，而非误把仿真失败当通过。

### 实际XFFT/CORDIC完整链路

入口：`scripts/run_fft_rom_alignment_sim.ps1`；原`run_behavioral_sim.ps1`也继续使用已增强的tb_fft_processor。

使用仓库真实生成的ROM、XFFT和Translate CORDIC功能网表。参考系数直接读取十进制COE，逐样本检查ROM寄存器配对及AXI输入乘积，共三帧24576点：两帧不复位连续运行，第三帧在算法复位后运行，覆盖ROM输出保留状态。还检查8192次读/输入每帧、4096次频域写每帧、完成事件、TLAST错误事件及AXI保持规则。它检查输入golden与完整链路进度，不是对8192个FFT输出幅值逐bin作独立数值签核。

完整链路已通过：三帧24576次系数/样本及AXI输入golden核对，不复位连续运行及算法复位后的运行均通过，每帧4096次频域写入和完成事件/TLAST检查通过。见[实际IP回归结果](real_ip_result.txt)。功能网表本次仿真墙钟耗时约16分钟，模拟时间1.91151ms；这不是硬件处理耗时16分钟。工作区完整日志在`test_results/fft_rom_alignment_sim`。

## 上机边界

无需重新生成ILA/ROM/FFT IP，但需要用户重新综合、实现、检查WNS/WHS后生成新bit和匹配LTX。先通过JTAG下载测试，不必立即更新配置Flash。schema3候选观测保持启用。

此修复纠正已证实的系数配对缺陷，**尚未证明它能单独解决实板单音拒绝**。理想模型里旧错位窗也能识别单音，因此新bit仍需读取原始候选峰定位资格拒绝原因，然后再继续幅值标定。
