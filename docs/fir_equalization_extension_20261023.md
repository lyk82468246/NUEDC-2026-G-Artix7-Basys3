# 均衡候选低端及非整频点扩展测试（2026-10-23）

## 目的与版本

延续[四频点均衡实测](fir_equalization_hardware_20261023.md)，补测10/50kHz低端和10.25/100.25/499.75kHz半频点。不改变接线、开关、RTL、IP或标定参数；助手不综合、实现、生成bit、烧写或复位。

沿用用户22:46:24生成并已烧写的bit（SHA256 `530EA177442E385BF7A9390EAD4CBF1D60AC5FBAD06A466C2267FCEEA35FEE0C`）与匹配LTX。启动前只读inspect确认活动系数Vpp=3623460、RMS=3701829、FFT=4194、epoch=1；不是重载参数。原临时参考仍是发生器HIGHZ设定值，非输入端独立电压。

## 事务与安全

23:03:18 HDS回读SINE、500kHz、100mVpp、HIGHZ、0V、OFF。OFF前置任务 `e0c30e07318743e9bceb5a82ba9ed83a` 于23:04:05完成，ILA恰有一个measurement_valid：controls=4（B/连续），signal_valid=0、error_code=0、acquisition_fault=0；Vpp31、RMS4 raw，FFT/索引/频率全0。确认状态后才提交输出计划。

会话目录 `test_results/lab_2026-10-23T23-02-43.865+08-00_48b47e`；计划 `044ab56bc2b242a782cfe7bbdf2d41a5`。五个频点、每点两帧、100mVpp、高阻、零偏置，逐点关闭输出配置/回读，稳定2秒，再独立重新武装ILA。示例计划见 `scripts/instruments/sweep_equalization_extension.json`，仓库默认接线确认false，不能直接当作已授权的无人值守任务。

## 判据和分析方法

- 每帧一个新的measurement_valid，寄存器与任务记录一致，B/连续且无故障、单音候选唯一。
- 本次更严格的频率表征限值250Hz（半个500Hz bin），不把题目1kHz要求或旧报告默认值偷偷替换。分析脚本新增显式 `--frequency-tolerance-hz`；省略仍为1000，拒绝负数、NaN、无穷和不明确类型。
- 将raw按存档临时系数离线重算，Vpp/RMS/FFT峰值与100/35.355/50mV设定参考比较，三项绝对偏差各≤5mV。不是本轮VIO电压包读数，不声称输入端绝对标定或HMI已经显示校准值。
- 分别记录事务执行、频率与幅值一致性，不将通信完成等同测量通过。

主机离线93项回归通过，包含新增频率限值测试：250Hz边界可通过，收紧到249Hz明确失败，非法限值在读取数据前被拒绝。不改变FPGA频率算法。

## 结果与未测项

计划23:09:18完整完成，10帧均恰有一个新measurement_valid，signal_valid=1、controls=4、error_code=0、acquisition_fault=0，候选仅一个且与频率索引对应。频率与幅值参考一致性均通过。

| 输入Hz | 两帧输出Hz | 两帧Vpp raw | 两帧RMS raw | 两帧FFT raw | Vpp参考mV | FFT峰值参考mV |
| --- | --- | --- | --- | --- | --- | --- |
| 10000 | 10000 / 10000 | 1785 / 1784 | 624 / 624 | 779583 / 779487 | 98.637～98.692 | 49.884～49.890 |
| 50000 | 50000 / 50000 | 1793 / 1793 | 625 / 625 | 780377 / 780462 | 99.134 | 49.941～49.946 |
| 10250 | 10500 / 10500 | 1787 / 1782 | 624 / 624 | 778826 / 779208 | 98.526～98.803 | 49.841～49.866 |
| 100250 | 100500 / 100500 | 1790 / 1791 | 625 / 626 | 780098 / 779844 | 98.968～99.024 | 49.906～49.923 |
| 499750 | 500000 / 500000 | 1793 / 1790 | 625 / 626 | 779837 / 780279 | 98.968～99.134 | 49.906～49.934 |

所有半频点选择上侧相邻bin，不是声称频率插值到250Hz；整频点误差0Hz、半频点误差+250Hz。平顶窗峰值在这三个非整频点未显著塌陷，最高边界附近没有产生新的单音无效判定。
最大Vpp/RMS/FFT峰值参考偏差分别1.474/0.10834/0.159mV。RMS参考范围35.247～35.360mV。机器报告见[十帧分析](fir_equalization_extension_20261023_analysis.json)，明确记录频率限值250Hz、绝对输入校准false和VIO测量false。23:09:59再次sync确认499.75kHz/100mVpp/HIGHZ/0V/OFF。

OFF收尾任务 `a1a6d57bb48f40958f0bf3e7871ef7f1` 于23:10:25完成：一个新的measurement_valid；Vpp30、RMS4 raw，FFT/索引/频率0，signal_valid=0、controls=4、error_code=0、acquisition_fault=0、候选全0。23:10:41最终sync再次确认OFF，随后正常关闭服务并释放设备。无USB通信故障，未调用其他信号源或改变输出限值。

复现分析（输出文件须不存在）：

```powershell
.\.venv-hds\Scripts\python.exe scripts/instruments/analyze_sine_sweep.py `
  test_results/lab_2026-10-23T23-02-43.865+08-00_48b47e/044ab56bc2b242a782cfe7bbdf2d41a5 `
  --expected-controls 4 --frequency-tolerance-hz 250 --output test_results/eq_extension_review.json
```

本轮未进行模式切换，不能据此签核A模式控制。现有单音测试不能代替强谐波/弱基波、多音相位、C干扰/抗混叠、250mVpp量程、实屏显示和两秒端到端验收。运行Vivado进程的PC采集时间不等于FPGA处理或屏幕刷新耗时。
