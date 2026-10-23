# 组合信号参考模型、定点标度与验证边界

日期：2026-10-23。代码：`scripts/contest/reference_model.py`、`test_reference_model.py`。只使用 Python 标准库，不控制 USB/JTAG。

## 1. 输入与数据路径

输入 `Tone(hz, peak_mv, phase)` 中幅值是正弦峰值，phase 为弧度。组合信号使用 16 倍采样密度估计极值并归一化到指定总 Vpp；这仍是数值近似，不是发生器标定值。8192 点有限记录真 RMS 与完整周期理想平方和 RMS 分开记录。

人工 fixture 标度 `RAW_PER_MV=32` 仅用于构造测试数据；不是板上 ADC/模拟前端增益。输入量化为 12-bit offset binary，再转换为 signed16（左移4位）。窗系数采用与设计相同的 5 项对称平顶窗，Q1.15 量化后与输入相乘，算术右移15并饱和，再送浮点 FFT。

模型不模拟 FIR 启动瞬态、去 DC IIR、ADC CDC、FFT 内部蝶形舍入和 CORDIC 所有迭代；生成的频谱 fixture 用于独立验证谱峰分析，不可称作 ADC→UART 逐位端到端仿真。

## 2. 幅值比例推导

令量化窗 `w[n]=signed_q15[n]/32768`，`S=sum(w[n])`，相干增益 `CG=S/8192`，不是直接采用未量化的常数。离 DC/Nyquist 足够远的整 bin 正弦，峰值为 `A_raw` 时：

```text
|FFT[k]| ≈ A_raw × S / 2
X/Y送CORDIC = FFT实/虚部 >>> 1
CORDIC输入 = SignedFraction 30bit，28个小数位
CORDIC输出 = SignedFraction 31bit，29个小数位
raw输出 ≈ 2 × hypot(X_raw,Y_raw) ≈ |FFT[k]|
因此 A_raw ≈ 2 × magnitude_raw / S
```

不能只看到输入 `>>>1` 就把输出幅值也当作原 FFT 的一半。新增独立 raw 数值断言，避免“模型乘错二倍、反算再除错二倍”相互抵消而测试仍通过。`tb_cordic_magnitude_scale.sv` 以真实生成的 IP 网表测试原始码比例及正负象限，不改 IP 配置。

实际输入端峰值 mV 还要乘物理通道增益。`Measurement_Calibrator` 为时域与频谱各预留 unsigned Q8.24 mV/raw；配置有效性、舍入和溢出均独立处理。当前没有经过参考测量核定的有效系数，不能将模型人工标度写入硬件作为标定。

## 3. 测试与限制

生成七组 A/B 合法组合，包括 10.5/31.5/42 kHz（第三谐波更强）、最高成分200/500 kHz、非整 bin、两成分及相位变化。生成目录默认 `test_results/contest_reference`：每例时域8192点、频谱4096点、7字期望快照和 JSON 描述。仿真脚本自动生成，不必将大批 mem 文件提交仓库。

独立 Component_Analyzer 使用最多三轮扫描和 ±6 bin 主瓣排除，按频率排序，检查近似整数谐波关系；不是寻找前三个最大频点。阈值是可配置绝对/相对门限，没有任意弱基波抗噪保证；不一致时保留分量表但基频置零。当前尚未接入生产顶层。

Python 检查理想 FIR 对 1 MHz 的稳态抑制，也明确测试 4 MHz 在 4.096 MSPS 下会混叠到96 kHz、数字 FIR 不能事后排除；后者是应被识别的限制，不是 C 模式达标。模拟抗混叠、前端幅相、50～250 mV范围内≤5 mV误差和两秒可见响应必须实测。
