# 对称 FIR 均衡候选：首次实板对照（2026-10-23）

## 版本与边界

用户手动完成综合、实现、生成 bit/LTX 及烧写；助手只核对文件、连接 JTAG、加载 VIO 临时参数并采集，不执行构建、program 或复位。屏幕未连接。

- bit：`G_FPGA.runs/impl_1/G_FPGA_Top.bit`，2026-10-23 22:46:24；SHA256 `530EA177442E385BF7A9390EAD4CBF1D60AC5FBAD06A466C2267FCEEA35FEE0C`。
- LTX：同目录 `G_FPGA_Top.ltx`，同一时间；SHA256 `BEC03BDE11A2608AA0E9EC7EA63B88C6E1431C8E34D14AFD86407AEA733D36D8`。探针接口未改，所以 LTX 哈希与上版相同。
- 当前 routed timing summary：WNS +0.463ns，WHS +0.021ns，TNS/THS 0；报告声明所有用户指定时序约束满足。不是沿用旧 +0.147ns 报告，也不是对未约束路径或模拟接口的独立验收。
- XCI 的95个实数系数换算 Q1.15 后与对称候选一致，系数和32672；基线 COE 文件未覆盖。

本次 XCI 中 `Coefficient_Fractional_Bits` 实际为16，原版15；`C_ACCUM_PATH_WIDTHS` 与 `C_ACCUM_OP_PATH_WIDTHS` 为33，原版32。生成 MIF 的前48个有效整数系数对应候选 Q1.15 整数的两倍。不能据离线脚本的格式假设声称 IP 逐位等价；首次100kHz读数未出现整体二倍/半倍倍率变化，后续频带读数用于核对集成结果，仍不替代 IP 模型验证。关于参数含义参见 [AMD Quantize Only](https://docs.amd.com/r/en-US/2026.1/pg149-fir-compiler/Quantize-Only?contentId=gsRljfKmX8AGitw0jVgANw)。

## 参数与事务记录

最小链路：HDS242S OUT → 原模拟滤波器 → AD9226 模块 → Basys3；不额外并联示波器负载。

22:49:19 连接回读：SINE、500kHz、100mVpp、HIGHZ、0V、OFF。新烧写后的 VIO active gains/epoch 均为0。22:51:20 成功原子加载存档的临时系数 Vpp=3623460、RMS=3701829、FFT=4194，epoch=1、enabled=1，ack及活动参数回读匹配。单位为 Q16.16 的“发生器设定参考 µV/raw”，不是独立测得的输入电压。

只读初次 `read` 遇到结果更新窗口，被保护条件拒绝，未发布数据；之后用 `inspect` 读取配置，未将该失败解释为硬件故障，未重试参数写。

本次服务目录 `test_results/lab_2026-10-23T22-48-56.934+08-00_2c6e6f`；四点计划 `b85051218c87498a8e6c6cef74fcda50`。100/250/375/500kHz，各两帧；100mVpp、高阻、零偏置，逐点关闭输出配置并回读，稳定2秒，重新武装 ILA 等待新 measurement_valid；无 CH1/CH2 读数。

## 结果

计划于22:56:15完整完成，8帧均恰有一个新的 measurement_valid，controls=4（B/连续），signal_valid=1，error_code=0、acquisition_fault=0，单一候选索引正确。输出随后回读为OFF。

| Hz | 两帧 Vpp raw | 两帧 RMS raw | 两帧 FFT raw | Vpp参考 mV | RMS参考 mV | FFT峰值参考 mV |
| --- | --- | --- | --- | --- | --- | --- |
| 100000 | 1791 / 1795 | 626 / 626 | 781145 / 781181 | 99.024～99.245 | 35.360 | 49.990～49.992 |
| 250000 | 1788 / 1794 | 625 / 625 | 781052 / 780713 | 98.858～99.190 | 35.303 | 49.962～49.984 |
| 375000 | 1790 / 1791 | 625 / 625 | 780210 / 780319 | 98.968～99.024 | 35.303 | 49.930～49.937 |
| 500000 | 1798 / 1791 | 625 / 625 | 780619 / 781098 | 99.024～99.411 | 35.303 | 49.956～49.987 |

频率误差均0Hz。相对100mVpp正弦设定（RMS约35.355mV、峰值50mV），最大Vpp/RMS/峰值偏差分别1.142/0.05234/0.070mV。500kHz Vpp由原版92.721～92.887mV改善到99.024～99.411mV，支持频响补偿方向有效；跨次测试仍可能包含源幅值漂移、接触与环境变化，不能将差值全部归因并当作独立计量校准。

数值是按存档系数对 ILA raw 离线重算，不是本轮 VIO 新包的电压读数，HMI也未改成校准电压。机器报告见[八帧分析](fir_equalization_20261023_analysis.json)：事务、频率有效性、100mV设定参考一致性均通过；`absolute_input_calibrated=false`、`runtime_vio_measurement=false`。

OFF独立采集任务 `e7bb8449aab147b382f6706ab95618dd` 于22:57:01完成：Vpp30 raw、RMS4 raw、FFT峰值0、索引/频率0；一个新的measurement_valid，signal_valid=0、controls=4、error_code=0、acquisition_fault=0，候选索引全0。噪声门控在本帧正常。22:57:41最终sync回读500kHz/100mVpp/HIGHZ/0V/OFF，然后正常关闭服务并释放设备；未开启其他发生器或提高输入幅值。

## 软件与后续

主机离线回归92项通过（包括4项FIR选择/回退脚本测试）。首次在受限环境运行遇到本机网络及临时目录权限失败，获准访问后原样重跑全部通过，未降低测试断言。脚本已兼容当前观察到的15/16小数位，其他格式继续拒绝；该脚本修改未应用到当前板上，不需要为文档/主机脚本变更重编bit。

尚未验收：新FIR的10～100kHz低端、非栅格、全幅度范围、独立输入电压/相位、多音、C抗混叠、长时可靠性及屏幕显示。不能将本次四个单音点的参考一致性通过写成完整B题或≤5mV绝对精度通过。原始数据仅保存在忽略版本管理的test_results目录，摘要与分析报告入库。
