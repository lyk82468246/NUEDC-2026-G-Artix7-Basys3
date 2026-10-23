# 整链FIR均衡离线研究与可回退试验（2026-10-23）

## 1. 结论与状态

**在指定前端模型和稳定态量化模型内，现有95抽头、16bit Q1.15足以同时做通带均衡和低通。建议先对称幅度均衡候选做受控上板试验，不优先引入非对称相位均衡。**

这不是实际幅相校准，也不是B/C题验收通过。实际相位未测、输入绝对电压未校准、多音实板未测。已混叠进通带的干扰不可能靠这个数字均衡器消除。
本轮没有操作仪器、复位FPGA、修改RTL/XCI/生产COE，也没有执行综合、实现、生成bit或烧写。新增安装脚本只是定义显式选择过程，尚未对实际GUI项目执行。

交付：

- [离线设计/模型脚本](../scripts/contest/frontend_equalization.py)
- [完整模型结果](equalization_study_20261023/study.json)
- [对称幅度均衡实验系数](equalization_study_20261023/amplitude_only_95t_q15.coe)
- [非对称相位比较系数](equalization_study_20261023/complex_inverse_95t_q15.coe)，仅用于比较，不由安装脚本选择。
- [实验选择/基线恢复脚本](../scripts/setup_fir_equalization_experiment.tcl)

## 2. 输入证据与拟合假设

证据是[B频带实板六帧报告](b_band_20261023_analysis.json)：250/375/500kHz、源HIGHZ设定100mVpp，RMS/FFT同比下降。拟合使用这些帧两条幅值路径的12项残差，它们彼此相关，不能当成12个独立实验或统计置信区间。

原理图模型为：

`H(f)=[1+3.6/(1+j*2*pi*f*3600*C)]^2`

以100kHz幅度归一化，拟合一个等效C和一个漂移/尺度辅助参数。结果：

| 参数 | 结果 | 含义 |
| --- | --- | --- |
| 等效C | 24.285pF | 模型参数，不能据此认定焊上的22pF实际就是24.285pF |
| 辅助标量 | 1.000414 | 拟合残差辅助量，不写入FIR或现有标定寄存器 |
| 最大相对拟合残差 | 约0.1445% | 三个频点拟合内残差，不是全频带或绝对准确度 |
| 相位 | 未测 | 采用上述拓扑的相位假设，不伪装成实测相位 |

报告记录NumPy/Python版本和输入COE、实板JSON的SHA256。三点幅值不能唯一识别ADC模块的完整模拟网络、相位、寄生参数或采样前带外响应。

## 3. 设计与定点流程

使用NumPy `lstsq`，不依赖SciPy：将正频率复频响约束拆成实部/虚部，求实系数最小二乘。频率约束为0～600kHz通带、600～900kHz余弦过渡、900kHz～Nyquist阻带，目标为低通乘前端逆响应及47采样公共延迟。阻带目标权重20，过渡带0.3。
幅度方案强制系数成对完全相同；相位比较方案允许非对称。两者均量化至Q1.15，逐项验证无系数溢出，长度95。通带/阻带报告是有限频率网格上的检查，不是连续频带数学最坏值证明。

模拟数据流：

```text
已知多音(参考mV)
  → 假设的模拟前端复频响
  → 12bit offset-binary量化、左移4
  → 95tap Q1.15整数卷积、算术右移15
  → AFE Q16直流估计器(shift12)、限幅
  → 稳定后由<=0到>0的过零取8192点
  → Vpp、整数均方/开方、Q1.15平顶窗FFT峰值
```

ADC模型沿用参考模型的人工`RAW_PER_MV=32`，**不是实际ADC模块的物理标定**。IIR预热16个4096采样时间常数，仅验证稳定态，不等于实际上电只等待4096样本的瞬态签核。
FIR输出算术假设为有符号累加后截去15小数位；溢出显式标记，未拿限幅掩盖错误。还没有用本次候选生成的Xilinx模型做逐位核对，也没覆盖ADC时序、CDC、随机AXIS背压或实际CORDIC舍入。

参考向量包含原有7组、4组250mVpp高带边相位组合、6个10～500kHz/离栅格单音、高频强谐波和高频离栅格组合，共19组。这里的250mVpp是合成模型测试，不是提高真实信号源输出的授权。

## 4. 模型结果

| 方案 | 最大通带幅度偏差 | 19组最大Vpp误差 | 最大RMS误差 | 最大分量峰值误差 | 系数 |
| --- | --- | --- | --- | --- | --- |
| 原95tap低通 | 约6.409% | 15.969mV | 5.670mV | 8.134mV | 对称 |
| 幅度均衡候选 | 约0.0513% | 0.687mV | 0.0249mV | 0.0765mV | 对称 |
| 复逆响应比较 | 约0.0710% | 0.625mV | 0.0492mV | 0.0862mV | 非对称 |

候选在这个假设模型的19组Vpp/RMS/谱幅检查均小于5mV，无ADC/FIR/DC限幅。这是模型内可行性，不应把这些小数直接当实板误差预算。

对称候选量化后阻带峰值约−63.15dB、1MHz约−85.57dB；原系数相应约−71.92/−77.11dB。即某些阻带频率的最坏抑制变弱约9dB，不能只报告1MHz变好。两者系数绝对值之和为1.8584与原1.9500，但不能仅据此签核所有输入幅度下的实际IP输出位宽。
幅度候选系数和32672而非32768，因为目标包含前端相对增益；不能事后强制归一化到1来改变目标。

为什么不优先非对称方案：本模型中模拟相位大部分是约0.55采样的共同延迟，不等于相同量级的波形失真；额外相位补偿并没有显著改善本组量化指标。保留对称结构是降低试验变更范围的选择，不是保证综合资源、布局和时序不变。AMD说明FIR Compiler会推断系数对称性，仍需核对实际IP配置和输出响应：[Filter Symmetry](https://docs.amd.com/r/7.2-English/pg149-fir-compiler/Filter-Symmetry)。对称MAC的padding也可能影响响应，应按[Coefficient Padding](https://docs.amd.com/r/en-US/pg149-fir-compiler/Coefficient-Padding)检查，不能以本Python模型替代IP验证。

## 5. 反例与不能承诺的部分

### 相位不可辨识

在模拟模型后增加`(1-s*tau)/(1+s*tau)`、tau=0.5µs的单位幅度全通，所有频率的幅值保持不变，但相位不同。原幅值数据不能区分它与原模型；在比较候选的高频多音反例中，Vpp误差达约14.19mV。
它只是逻辑反例，不是声称实际PCB存在该全通电路。说明“幅值拟合很好”不能自动证明多音Vpp已校准。等效C为22pF及拟合值±10%的失配比较也存于JSON（该失配批次针对复逆响应比较方案），最大Vpp误差约2.8～3.7mV；它不覆盖所有可能前端或相位。

### C模式的混叠限制

在假设未削顶的模型中，加入200mVpp/1MHz干扰，比较候选仍通过本组指标；改成4MHz后，混叠至96kHz，Vpp误差约40.84mV。数字均衡无法区分这条混叠分量与合法输入。
因此不宣称原模拟前端＋新FIR可覆盖任意`fJ>=1MHz`。仍需真实抗混叠能力、带外量程和独立模拟测试。

## 6. 验证与复现

本机使用NumPy2.3.5，依赖清单见`scripts/contest/requirements-equalization.txt`。本轮未安装或升级包。模型20项测试（原11项＋新9项）全部通过；标准库环境运行时新9项明确skip，不计成通过。选择/恢复脚本另有2项Tcl mock测试通过，未对真实Vivado项目执行。

```powershell
$eqPython = 'C:/Users/Joe/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe'
& $eqPython -m unittest discover -s scripts/contest -p 'test_*.py'
& $eqPython scripts/contest/frontend_equalization.py --output test_results/eq_new_run
.\.venv-hds\Scripts\python.exe -m unittest discover -s scripts/instruments -p test_fir_equalization_tcl.py
```

输出目录必须不存在。脚本不操作USB/JTAG，不启动Vivado，不覆盖原COE。JSON含19×3组主比较、51条参数失配、4条相位反例和2条干扰反例，共120条轨迹；原方案和反例的预期失败不算“120项测量验收通过”。

## 7. 下一步：显式选择、用户手动构建、可回退

当前生产文件仍是`sources/coeffs/fir_lp_600k_95t.coe`。IP实际使用`Coefficient_Source=Vector`，单纯把新COE放进目录不会自动生效。

需要做受控试验时，在正确工程的GUI Tcl Console执行：

```tcl
source C:/Users/Joe/Documents/Verilog/G_FPGA/scripts/setup_fir_equalization_experiment.tcl
fir_eq_select experimental
```

仅source不改项目；显式选择后，脚本验证现有系数/数据格式、95点、Q1.15范围、对称性，更新现有FIR的CoefficientVector并生成IP输出产物。不覆盖基线COE，不触碰VIO/ILA接口，不启动综合或烧写。
脚本目前只经过离线mock；首次真实IP配置如果报不匹配，停止并提供错误，不跳过保护。
之后由用户保存工程、检查实际IP对称性/响应，手动综合→实现→检查时序/DRC→生成bit/LTX→烧写。已有+0.147ns时序报告不适用于新系数版本，不能沿用签核。
上板先保持源OFF，重新加载临时VIO系数，再在原100mVpp上限内对照100/250/375/500kHz及OFF，确认500kHz恢复且低频未退化；再做非栅格、多音和独立幅相参考。新硬件验证前不把候选设置当正式校准。

恢复原FIR配置：

```tcl
fir_eq_select baseline
```

恢复也需要用户手动构建并烧写基线版本，或选择已备份、来源明确且匹配LTX的原bit；助手不会代执行。现有`setup_capture_calc.tcl`仍包含原始硬编码向量，再执行它会恢复原系数，这一点是有意保留的基线，不应误认为均衡仍启用。

本轮只把可行方案推进到可回退的实验交接点。模型之外的电压参考、相位、模拟抗混叠、多音实板和整个C题仍未验收。
