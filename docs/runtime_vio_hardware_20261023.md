# 首次在线标定硬件验证（2026-10-23）

## 已烧写版本与边界

用户确认已烧写最新版本，发生器→滤波器→50Ω ADC模块→FPGA均接好，屏幕未接。助手不复位、不综合、不实现、不生成bit、不program。
当前磁盘bit生成时间16:25:09、LTX16:25:10，用户确认用于本次烧写。

- bit SHA256：`FC97C8B8F17C20BC979F909CD6581642197FA613485E9FCA2B306CF1A453B553`
- LTX SHA256：`BEC03BDE11A2608AA0E9EC7EA63B88C6E1431C8E34D14AFD86407AEA733D36D8`
- 用户实现报告：WNS+0.147ns、WHS+0.014ns，全部用户时序约束满足；归档[时序报告](../reports/manual_gui_vio_20261023_timing.rpt)。这不是本轮重新运行实现得到的报告。

幅值参考沿用[临时标定](runtime_calibration.md)，即发生器HIGHZ显示值，不是独立测得的滤波器输入实际电压。不因在线系数生效而宣称绝对精度合格。

## 首次连接发现与修复

只读枚举发现标定bank默认全0、flags=0，count非零且递增；新bit确实含VIO，屏幕断开时测量仍在运行。
硬件连接暴露了离线mock未充分覆盖的工具行为，均只修主机脚本、不改RTL：

1. Vivado2025.2的`refresh_hw_vio -update_output_values`为开关参数，不能再跟`1`。第一次失败发生在只读阶段。
2. 实际探针使用`g_runtime_calibration.epoch`等点分层级名，不是斜杠，按精确末级信号名兼容两种形式。
3. HEX值必须补足位宽，32bit需8字符。第一次apply在首个`set_property`就被拒绝，尚未commit；修正补零并明确HEX后再提交，不重试未知已提交写操作。

成功提交：Vpp3623460、RMS3701829、FFT4194，ack正确、活动系数回读一致，epoch=1、enabled=1。没有bit重烧。
本地会话目录`test_results/runtime_vio_first_20261023`；失败日志保留于inspect/apply_nominal，成功日志为inspect_corrected/apply_padded。

## 100kHz在线结果

源设定HIGHZ、0V偏置，测试不超过100mVpp。以下mV全部是临时参考单位。

| 源设定mVpp | 新包计数 | Vpp参考mV | RMS参考mV | FFT峰值参考mV | 状态 |
| --- | --- | --- | --- | --- | --- |
| 100 | 45459 | 99.466 | 35.416 | 50.137 | epoch1、flags3、有效 |
| 100 | 45460 | 99.300 | 35.416 | 50.123 | epoch1、flags3、有效 |
| 50 | 45959 | 50.314 | 17.736 | 25.087 | epoch1、flags3、有效 |
| 50 | 45960 | 50.092 | 17.736 | 25.071 | epoch1、flags3、有效 |

`read`会读取两个版本一致且计数不同的包，10秒内无新稳定包则报错，不拿重复计数当新测量。VIO逐项读，采用两次计数/版本/flags核对避免拼接；不等于与另外启动的ILA抓取同一帧。

独立100mVpp ILA任务`4471b44628ea4e4e91efe2dced553272`：Vpp1795raw、RMS627raw、FFT783167raw、100kHz、仅bin200，signal_valid=1、error_code=0、acquisition_fault=0，有新measurement_valid。数据目录`test_results/lab_2026-10-23T21-28-29.931+08-00_a36592`。单独VIO读数与该ILA不属于同一包，仅用于稳态范围一致性对照。

50mVpp ILA任务`50aab4c392c84d2bbefc79c3e02edfc8`：Vpp906raw、RMS314raw、FFT391946raw，最终100kHz，独立新触发。频率和幅度减半关系正常。

## 收尾期间的拒绝记录

21:35:44首个OFF查询短暂回读ON，`output_off`任务明确报失败；安全路径随后两次OFF回读成功并将服务置faulted、释放设备，不继续沿用已核验参数。21:37:26显式重连回读OFF，再发OFF并确认成功，未自动恢复ON。不能把失败任务改写成首次成功，也不能因旧last_error保留就认定源仍ON。
OFF时`read_off`出现`Result changed/in progress; read again`，这是跨包一致性检查拒绝，不是返回一份旧有效结果。OFF包更新较快，尚未给严格双读建立稳定快照；不通过放宽检查来宣称完整帧读回。另用只读inspect确认当前失效/零值，并以ILA新帧补充检查。

`inspect_off`：epoch/result_epoch均1，ack/request均1，活动系数保持正确；count=0xF1A9，flags=01（系数有效、测量无效），三个µV输出均0。这是只读当前状态快照，不冒充严格双读通过的新有效测量。
OFF ILA任务`065157eb745b442c8429fcfb5a21a0bc`含一个新measurement_valid：Vpp29raw、RMS4raw，候选全0、最终频率/FFT幅值0，signal_valid=0、error_code=0、acquisition_fault=0。
21:39:04最终sync回读100kHz/50mVpp/HIGHZ/0V/OFF，再次OFF确认成功后关闭服务释放USB。系数仍留在FPGA易失寄存器，重启/复位后需按指南重新提交和确认；本轮无RTL修改，不需重建bit。

结论：首次硬件在线加载和100/50mVpp新包标定回读已通过，无信号失效/清零状态正确；严格VIO双读在快速OFF包场景仍可能拒绝，不能把它写成所有速率下均可无阻塞原子读取。后续若需对快速流保证任意时刻一致读取，应在RTL增加主机请求式快照/冻结握手，而不是删除一致性校验。未做独立绝对电压、全频响、多音/C模式或屏幕验收。

## 工具使用

新增`scripts/instruments/runtime_vio.py`驱动有界90秒Vivado硬件会话，`runtime_calibration_hw.tcl`只支持inspect/read/apply。使用与ILA相同跨进程锁，不program、不reset，不自动重试参数写。用户GUI/其他JTAG工具需避免同时操作；仪器服务可空闲轮询USB，但不得同时提交FPGA任务。

```powershell
.\.venv-hds\Scripts\python.exe scripts/instruments/runtime_vio.py read `
  --ltx G_FPGA.runs/impl_1/G_FPGA_Top.ltx `
  --directory test_results/vio_new_read
```

输出目录必须不存在。脚本保存Vivado日志和Tcl字典格式result.txt，不伪装成JSON。独立进程启动连接需数十秒；这不是FPGA算法延迟。使用已经打开的GUI调用`rc_apply/rc_read`可避免反复启动Vivado，但仍须遵守唯一JTAG操作者规则。

修正后47项Python离线回归通过，新增检查点分层级名、refresh开关格式和HEX位数。本轮无RTL修改，不需要重建bit。
