# 三分量幅值观测：RTL与仿真交接（2026-10-24）

后续：用户已完成00:33的手动构建和烧写，新15探针已实际读通并完成三分量幅值对照，见[首次实板验证](component_amplitudes_hardware_20261024.md)。以下“尚未构建”等表述只记录原修改/仿真交接阶段，不代表最新板上状态。

## 改动边界

本轮只改源码、项目源文件注册、用户手动IP配置脚本、仿真与主机解码。没有启动综合、实现、生成bit、烧写、操作仪器或改变标定系数。板上仍是此前22:46的旧版bit；仓库中的ILA XCI/输出产物也仍是旧十探针配置，**必须先运行下述GUI Tcl再综合**。

Component_Analyzer原本已有最多三个频率排序后的完整32bit raw幅值，算法不变。顶层现在接出count/bins/magnitudes，增加只读Measurement_Debug_Snapshot；Capture_Calc_Subsystem仅移动两条既有wire声明以满足XSim严格的先声明检查，不改功能。

## 同帧契约

```text
HMI measurement_valid ──┬── 原Run_Controller/Runtime_Calibration（原时序不变）
                       └── Debug Snapshot在同一上升沿锁存：
                           Vpp/RMS/基波、三分量、frame_id、active epoch、模式/有效位
                                  ↓ 寄存器和valid在同一NBA更新
                        debug_measurement_valid → ILA probe0
```

ILA触发晚一拍（100MHz下10ns），不是测量结果或UART整体延迟一拍。触发采样时所有快照寄存器已经稳定。无commit时保持，复位清零；无效信号仍保留raw Vpp/RMS供噪声诊断，但基波/分量数/槽位清零。3→1/2分量时未使用槽位显式清零，不能遗留旧谐波。

frame_id来自Run_Controller本事务编号，复位重新计数，32bit回绕；不表示永久唯一ID。calibration_epoch是Runtime_Calibration接收同一测量事件时使用的active bank版本，不是其稍后完成包的计数；采样与更新请求同拍时采样优先，两者都使用旧epoch。VIO关闭配置下epoch/校准有效位为0。

## 新ILA接口（schema 2）

| Probe | 信号 | 位宽 | 含义 |
| --- | --- | --- | --- |
| 0 | debug_measurement_valid | 1 | 新的同帧快照触发 |
| 1 / 2 | debug_vpp / debug_rms | 17 / 16 | raw，无符号，Vpp不再截掉最高位 |
| 3 / 4 | debug_fundamental / debug_fundamental_bin | 32 / 12 | 基波raw幅值/索引，幅值不再截为31bit |
| 5 | uart_state | 5 | 实时诊断 |
| 6 / 7 | diagnostic_status / diagnostic_adc | 32 / 12 | 实时状态和ADC，不属于原子快照 |
| 8 | debug_component_bins | 36 | 低12bit为槽0，依次槽1/2；已按信号有效性限定 |
| 9 | diagnostic_noise | 32 | 实时背景估计 |
| 10 | debug_component_magnitudes | 96 | 每槽32bit无符号raw，低32bit为槽0，与probe8对应 |
| 11 | debug_component_count | 2 | 0～3个有效分量 |
| 12 / 13 | debug_frame_id / debug_calibration_epoch | 32 / 32 | 同帧编号与标定版本 |
| 14 | debug_metadata | 8 | bit0信号有效，bit1校准启用，bit2有VIO，bits4:3模式，bit5单次，bit6三周期，bit7保留0 |

深度保持1024，总探针宽度365bit。旧版placed报告占42/50 Block RAM Tile，新配置会增加观测存储；不能用旧利用率或旧WNS签核新配置，需用户重新检查实际资源与时序。未为本改动扩大其他BRAM或FFT。

原probe8为未限定的原始候选，新probe8为同帧有效槽；无效时清零是有意变化。probe6等实时信号可能随采样窗口变化，主机不能将它们当作标定版本依据。

## 仿真与软件验证

新增XSim快照断言覆盖：17/32位最高位不丢失、同拍锁存与保持、3→1清槽、无效清零、复位、无VIO字段、采样/参数更新同拍和旧结果不被新epoch重标。原Runtime_Calibration断言另行回归。
真实顶层RTL分别以VIO开/关两种参数展开，使用仿真专用15探针ILA端口契约和其余IP黑盒声明检查连接；**这不是ILA内部行为仿真，不证明新IP已生成或时序通过**。仿真专用`sim/ila_system_debug_contract.sv`不注册到综合fileset。
原九组contest控制/AFE/分量/HMI回归也执行。日志位于test_results/measurement_debug_sim、runtime_calibration_sim、contest_sim；后续DSP行为回归结果以本文件收尾记录为准。

最终结果：新增快照断言及VIO开/关顶层连接契约通过；Runtime_Calibration原断言通过；九组contest回归全部通过；四组原行为回归（真实CORDIC平方根模型、8192点FFT/ROM/Translate模型、Peak_Search、BIN2BCD/UART/HMI）全部通过。FFT完成8192次时域读取和4096次频域写入，反压保持与TLAST断言通过；该门级模型仿真耗时约5分13秒，不是硬件处理时间。主机回归105项通过。
当轮快照/连接/标定及九组contest通过日志归档在[reports目录](../reports/measurement_debug_20261024/)。顶层连接检查有意使用IP黑盒，不替代四组独立真实模型回归，更不替代新ILA的实际生成、综合、资源和时序检查。

复现命令（只仿真，不构建bit）：

```powershell
.\scripts\run_measurement_debug_sim.ps1
.\scripts\run_runtime_calibration_sim.ps1
.\scripts\run_contest_sim.ps1
.\scripts\run_behavioral_sim.ps1
.\.venv-hds\Scripts\python.exe -m unittest discover -s scripts/instruments -p 'test_*.py'
```

新主机解码兼容旧CSV；新CSV按debug_measurement_valid事件解码，拒绝重复别名、部分schema、无效残留、未使用槽非零、槽0与基波不符、触发后快照变化。UTG试验遇到新schema时比较三个分量的峰值；仍用同一临时FFT比例，不声称逐频独立校准。重复frame_id或同一trial中epoch变化拒绝接受；旧CSV继续明确标记“未观测全部幅值”。

## 用户手动构建（本轮不要误用全工程重建配置脚本）

在当前工程GUI Tcl Console执行：

```tcl
source C:/Users/Joe/Documents/Verilog/G_FPGA/scripts/setup_measurement_debug.tcl
```

它仅注册快照源文件，设置现有ILA为15探针并生成ILA输出产物；不碰FIR、MMCM、VIO，不启动综合。工程若已开着，不依赖外部修改xpr自动重载，脚本会在当前内存工程中补注册。不要为此重新执行setup_capture_calc.tcl，以免恢复原FIR向量。

检查顶层G_FPGA_Top、当前FIR仍为均衡候选、ENABLE_RUNTIME_CALIBRATION保持现有1；保存工程。然后由用户手动综合→实现→检查资源/DRC/WNS和保持时序→生成bit及**新的匹配LTX**→烧写。新旧ILA宽度及名称已变，绝不能沿用旧LTX。

烧写后先保持UTG两路OFF；标定bank会被复位，助手先inspect并按原流程重载临时系数，再做单音、三分量及弱基波实板验证。完成后仍需验证高频复合信号、相位、全幅范围、C抗混叠和实屏，不把本轮仿真当硬件验收。
