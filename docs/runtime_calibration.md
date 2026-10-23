# 临时幅值标定与 JTAG 在线调参

日期：2026-10-23。当前板上仍为用户14:24手动生成烧写版本。本轮不综合、不实现、不生成bit、不烧写。

## 1. 标定参考及限制

用户批准暂按发生器设置值标定。发生器100kHz正弦、HIGHZ、0V偏置；滤波器输入50Ω对地，输出串联50Ω，ADC模块输入50Ω。
**这里的mV是发生器HIGHZ显示值的等效参考，不是已实测的滤波器输入端mV。** 如果源等效内阻50Ω，实际输入端可能约为显示值一半；本次不擅自乘/除2。改变负载模式、接线、前端、采样配置后必须复核系数。
RMS参考由正弦Vpp/(2√2)推得，FFT参考为Vpp/2的正弦峰值，不是独立仪表实测。不宣称完成≤5mV精度验收。

## 2. 六帧实测与系数

本地原始目录`test_results/lab_2026-10-23T15-42-00.184+08-00_5455dc`。
计划`c05261c332734165af8068f50aad608e`先完成50mVpp两帧，随后75mVpp被仪器回读为70mVpp，因不匹配自动停止并关闭OUT；没有把70的数据标成75。随后计划`db017df283cc4fb1acb47d3acd78e782`明确测试70/100mVpp各两帧成功并自动OFF。没有降低回读核验标准。

| HIGHZ设定mVpp | 两帧Vpp raw | 两帧RMS raw | 两帧FFT raw |
| --- | --- | --- | --- |
| 50 | 913 / 909 | 313 / 313 | 390850 / 390549 |
| 70 | 1274 / 1266 | 438 / 438 | 547021 / 546994 |
| 100 | 1803 / 1802 | 626 / 626 | 781105 / 781118 |

所有帧为新measurement_valid，signal_valid=1，仅100kHz候选。15:47:48再次确认OUT OFF，关闭服务。三档均处于既有100mVpp测试上限内，未提高至250mVpp。

通过原点的最小二乘系数，采用独立Vpp/RMS/FFT系数：

| 输出参考 | µV/raw | uint32 Q16.16系数 | 最大拟合残差 |
| --- | --- | --- | --- |
| Vpp | 55.289605 | 3623460 | 约479µV |
| RMS | 56.485435 | 3701829 | 约8.12µV |
| 正弦FFT峰值 | 0.064000396 | 4194 | 约12.90µV |

公式：`reference_uv = saturate_uint32((raw * gain_q16 + 32768) >> 16)`。
这些残差是训练数据内的残差，不是独立验证或参考仪器不确定度。Vpp用全帧极值，受噪声偏置影响；其诊断性自由截距约−1.16mV，暂不应用截距修正，不把小信号修正公式泛化到所有组合波形。单一100kHz系数尚不能补偿整带幅相响应，也没有验证多音Vpp/真RMS及非栅格频谱峰值。

可复现拟合：

```powershell
.\.venv-hds\Scripts\python.exe scripts/instruments/fit_amplitude_calibration.py `
  test_results/lab_2026-10-23T15-42-00.184+08-00_5455dc/c05261c332734165af8068f50aad608e `
  test_results/lab_2026-10-23T15-42-00.184+08-00_5455dc/db017df283cc4fb1acb47d3acd78e782 `
  --output test_results/calibration_new_report
```

输出目录必须不存在；脚本不接触硬件。存档系数与报告见[系数数据](calibration_generator_nominal_20261023/coefficients.tcl)和[拟合报告](calibration_generator_nominal_20261023/calibration.json)。仅统计完成的逐点记录，即使所在计划后续失败，已完成50mVpp样本仍可用；拒绝模拟数据、旧帧、无效信号、多候选、错误频率和非HIGHZ记录。

## 3. 在线调试结构与安全默认值

```text
VIO输出暂存系数 ──单独提交request toggle──> Runtime_Calibration
                                                 │
原始measurement_valid＋raw ──> 每包锁存系数及版本 ──> µV结果
                                                 │
                      VIO输入 <── ack/版本/计数/状态/实际系数
原有ILA、有效判决、HMI和数码管raw路径：保持原样
```

`G_FPGA_Top.ENABLE_RUNTIME_CALIBRATION`默认0，兼容现有工程。运行安装脚本后改为1，新增VIO旁路；不改变原有10探针ILA，不把校准量替换成内部滤波/触发样本。现有HMI仍显示raw，不能把它当已校准mV。
VIO输出和活动系数初始化0，标定无效。系数为易失寄存器；掉电/重新烧写后需重新加载，板级复位后也应重新提交并确认。不得把“bit已含VIO”当作“系数已经加载”。

每次只有一个未确认请求。先写四个暂存字段并commit，再单独翻转request并commit。等ack相等后，回读活动系数确认。RTL仅在处理包间隙接受新bank，每包锁存自身epoch。更新后旧结果不会被新版本重新解释；等下一包result_epoch==epoch再使用。默认不允许使用零系数、溢出或无信号结果。

## 4. 用户首次手动构建（仅一次）

在当前正确目录的Vivado GUI Tcl Console执行：

```tcl
source C:/Users/Joe/Documents/Verilog/G_FPGA/scripts/setup_runtime_calibration.tcl
```

脚本注册Runtime_Calibration并生成vio_calibration IP输出产物，保留已有generic覆盖，仅设置ENABLE_RUNTIME_CALIBRATION=1。不调用综合、实现、bit或program，不关闭项目。保存工程，检查新增模块/IP可见。
随后由用户手动完成综合→实现→检查时序/DRC→生成bit→下载，并关联同次生成的LTX。**完成后告诉助手**，再验证实际VIO探针名称及在线事务。本轮没有运行此安装脚本，未生成新VIO IP或bit；IP配置字段、顶层完整连接及新增资源/时序仍待首次GUI构建验证。

## 5. 已烧写后在线加载，不再重编译

先停止自动服务/ILA任务，使用同一个Hardware Manager连接，禁止多个工具抢JTAG。

```tcl
source C:/Users/Joe/Documents/Verilog/G_FPGA/scripts/runtime_calibration_vio.tcl
source C:/Users/Joe/Documents/Verilog/G_FPGA/docs/calibration_generator_nominal_20261023/coefficients.tcl
rc_apply [dict get $rc_coefficients vpp] [dict get $rc_coefficients rms] [dict get $rc_coefficients fft]
rc_read
```

`rc_apply`校验uint32、两阶段提交、ack和活动系数回读；超时不重放未知写操作。`rc_read`返回µV、epoch、result_count及valid。单位仍是本次系数定义的“发生器设定参考µV”。同一系数下按`µV/1000`换算参考mV。
VIO读数是逐项读取，不是原子抓拍：脚本对比两次计数、版本、状态并拒绝busy/跨版本结果。调用者必须观察result_count增加才可声称新包，重复读到相同计数不是新测量。
探针按精确末级信号名匹配，遇到缺失/重名直接报错；首次上板若综合命名变化，先检查`get_hw_probes`，不模糊匹配任意同宽探针。当前脚本通过离线Tcl mock事务测试，尚未实际VIO硬件验证。

关闭标定而不重编译：

```tcl
rc_apply 0 0 0 0
```

目前只提供三项幅值系数，不支持在线重配FFT长度、FIR结构或MMCM，这些仍需重新生成硬件。动态RMS门限、频响表和全谐波校准可后续扩展；本次不修改信号判决。

## 6. 验证记录

新增Runtime_Calibration行为仿真覆盖初始无标定、请求延后、每包锁存、版本、无信号、舍入、饱和、忙时输入诊断及复位。运行`scripts/run_runtime_calibration_sim.ps1`。
既有九组contest RTL仿真复跑通过。仪器/拟合/Tcl mock共46项Python测试通过；mock曾发现Tcl `%x`将FFFFFFFF读成−1，已修正为严格校验后的无符号解析并通过回归。
这些不替代首次带VIO顶层的综合、布线时序及实板验收。
