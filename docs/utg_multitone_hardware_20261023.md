# UTG932首次接入与多音实板试验（2026-10-23）

## 连接、版本和参考

用户确认UTG932 CH1输出已接到滤波器输入。保持原滤波器→AD9226→Basys3链路、B/连续开关、22:46均衡bit及匹配LTX，不综合、实现、生成bit、烧写或复位；不改VIO系数，不启用HDS输出。首次双通道查询均OFF，CH1为400kHz/100mVpp/HIGHZ/0V，CH2为1kHz/100mVpp/50Ω/0V。

使用`utg_fpga_trial.py`固定试验脚本，默认dry-run。每次执行独占UTG和试验服务锁，读取参数、关闭状态下配置并核对；CH1输出稳定2秒，再独立捕获两次新的ILA事件。每帧前后回读设置，发现变化不接受该帧；成功、失败和取消均在finally尝试关闭两路，OFF未确认明确标为失败，不自动重试ON。连接/设备锁失败不留running状态，已有结果不覆盖。

仍沿用HDS设定值建立的临时Q16.16系数（Vpp3623460、RMS3701829、FFT4194）。更换源可能带来增益差；不偷偷重拟合使结果通过。以下电压为ILA raw按原系数离线重算，与UTG HIGHZ设定/合成数学参考比较，并非独立输入电压标定、VIO电压包或实屏读数。

## 固定试验向量

| 案例 | 分量Hz | 各分量mVpp | 各相位度 | 理论总Vpp mV | 理论RMS mV | 基波峰值mV |
| --- | --- | --- | --- | --- | --- | --- |
| sine | 100000 | 100 | 0 | 100 | 35.35534 | 50 |
| harmonic | 50000 / 150000 / 200000 | 60 / 25 / 15 | 0 / 0 / 0 | 68.52053 | 23.58495 | 30 |
| strong_harmonic | 50000 / 150000 / 200000 | 10 / 50 / 40 | 0 / 90 / 0 | 87.75462 | 22.91288 | 5 |

ARB满量程设定100mVpp，所有分量Vpp之和≤100mVpp，所以即使峰值相加也不越过±50mV设定包络。实际合成总Vpp不是分量Vpp之和。完整周期理论RMS按分量均方和计算；总Vpp用65536个相位点求极值，是数值参考而非解析极值或真实端口测量。
4000点表分别包含1/3/4周期，重复频率50kHz。表中“有效采样率”是数学表点数×重复频率，不声称仪器实际DAC时钟或插值已验证。仪器相位/带宽、负载、模拟链相位和量化等仍影响输出。

上传使用先前助手创建的测试槽1（原TwoTone）并替换为FpgaTrial；不改槽0。上传例程先关闭两路、核对上传副作用，配置后再显式ON；没有设备采样表CRC/逐点回读，仅传输完成和源/槽/参数回读。CH2从未开启。

## 测量范围与限制

现有ILA可观察Vpp、RMS、基波幅值、三个排序后的候选索引和有效/故障诊断。只能验证三个频率和基波幅值，**不能验收三个分量各自的幅值**；第三/四谐波幅值未部署探针，屏幕也未连接。
检查每帧恰有一个measurement_valid、controls=4、signal_valid=1、error_code=0、acquisition_fault=0，候选索引与参考完全对应。三音预期[100,300,400]，基频索引100，即便最高谱峰在150kHz也不应将其当成基频。

## 结果

UTG100kHz单音两帧：Vpp raw1838/1838、RMS641/641、FFT801147/800752，索引200，频率100kHz；参考Vpp101.622mV、RMS36.207mV、峰值51.270/51.244mV。相对HDS略偏高，但三项相对UTG设定参考偏差均<5mV；不是两台源绝对电压相同的证明。

普通三音两帧：候选索引均[100,300,400]，基频50kHz；Vpp参考69.444/69.167mV，RMS23.950mV、基波峰值30.509mV。最大三项参考偏差分别0.9235/0.3651/0.509mV，均通过本轮限值。每次试验完成都先确认两路OFF，再进入下一案例。

强谐波两帧：候选索引均[100,300,400]，基频仍为50kHz，没有误选最强的150kHz；Vpp raw1598/1594、RMS412/412、基波FFT79566/79576。参考Vpp88.353/88.132mV、RMS23.272mV、基波峰值5.092mV。最大三项参考偏差0.5984/0.3592/0.092mV，均通过本轮限值。这个案例同时改变了分量比例与第三谐波相位，不是只改变相位的受控对照，不能据此签核实际模拟相位响应。

三次试验共六帧，每帧恰有一个新的measurement_valid、controls=4、signal_valid=1、error_code=0、acquisition_fault=0。每次结果都经参数前后回读核对；每次收尾两路OFF确认成功。汇总见[六帧分析](utg_multitone_20261023_analysis.json)，`overall_pass`仅针对已观测的Vpp/RMS/基波峰值/候选频率和关断，不是完整赛题验收；`all_component_amplitudes_observed=false`、`absolute_input_calibrated=false`。

新增脚本与保护回归后，主机离线100项测试通过，包括初始连接失败不留running、采集失败关闭两路、OFF未知不能发布completed、固定包络、弱基波、候选错误拒绝、已存结果防覆盖和归档保留失败状态。

23:59:32 OFF独立新帧完成：Vpp31/RMS4 raw，FFT峰值/索引/频率0，候选全0、signal_valid=0、controls=4、error_code=0、acquisition_fault=0。2026-10-24 00:00最终只读双通道查询仍均OFF；CH1保留50kHz重复频率、100mVpp满量程、HIGHZ、0V的用户槽1 ARB配置，CH2原设置不变。保留配置不代表输出开启，不要手动ON后忘记OFF。

## 复现接口

```powershell
# 默认仅生成参考参数，不操作仪器
.\.venv-hds\Scripts\python.exe scripts/instruments/utg_fpga_trial.py --case harmonic
# 仅在接线、量程、已烧写bit/LTX和独占访问均确认后执行；目录须不存在
.\.venv-hds\Scripts\python.exe scripts/instruments/utg_fpga_trial.py --case harmonic `
  --execute --directory test_results/my_new_trial
```

各次原始ILA/回读/SCPI/状态持久化在本机`test_results/utg_fpga_{sine,harmonic,strong_harmonic}_20261023`，默认不入库。输出在进程被强杀、掉电、USB故障时无法由软件保证关闭；OFF未确认需现场手动关闭两路。
