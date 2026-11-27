# 时域波形横向方向修订

日期：2026-11-27。RTL修改阶段仅进行离线仿真，未操作硬件。后续用户已手动构建、下载并确认实屏方向正确，又完成Flash升级与冷启动验证，见[本轮硬件证据](../reports/boot_release_20261127/README.md)。屏幕程序没有修改。

## 问题与依据

用户观察到Tk GUI预览与实屏时域波形左右镜像。`afg1022_gui.py`按递增样本序号向右绘制，`afg_contest_waveform.py`的预览与输出波形均沿正时间生成，`afg1022.py`按原序上传DAC码并逐点读回核对。FPGA采集BRAM也按时间递增写入。

此前只有频谱实现了反向发送补偿。`screen_axis_refresh_20261030.md`已记录wave可能存在同样问题，但当时尚未修订。此次据新实屏反馈补齐wave方向。未读取最终HMI工程属性，不能据此认定具体是哪项屏幕配置导致反向落点。此前源码注释中“新点在右”不能单独证明镜像方向，本次依据是用户实际观察和两条RTL路径的差异。

## 实现

新增参数链为`G_FPGA_Top.DISPLAY_WAVE_REVERSE_X` → `Capture_Calc_Subsystem.DISPLAY_WAVE_REVERSE_X` → `Display_HMI.WAVE_REVERSE_X` → `Display_Wave_Renderer.REVERSE_X`。前三者默认1，独立Renderer默认0以保留其逻辑正向接口。FFT参数独立，屏幕命令格式不变。

发送序号`s`始终从0递增至`W-1`，逻辑横坐标为`REVERSE_X ? W-1-s : s`。粗频率回退路径用该坐标计算BRAM分数地址。相位对齐路径原分子为`s×span_q12`，反向时改为`(W-1)×span_q12-s×span_q12`，再执行原来的整数除法和原点相加。这样保留原坐标量化，反向输出恰为正向点列倒序。

预扫描与实际绘制应用相同坐标映射，覆盖带限插值、线性插值、1T、3T及对齐失败回退。`PREP_SPAN`状态将整幅跨度分子单独寄存，再计算反向坐标，避免常数缩放与减法串在同一周期。常数乘法标记`use_dsp="no"`，不新增帧RAM或IP；最终资源及时序仍须新构建确认。发送结束仍由递增序号的最后一点决定，UART末尾STOP和帧释放机制不变。测量Vpp、RMS、频谱、触发与标定计算不变。

## 验证方法

最终RTL在Vivado XSim 2025.2中通过全部13个仿真顶层，三份运行脚本均退出0。归档包含[原始仿真输出](../reports/wave_direction_20261127/simulation_results.txt)和[源码/日志SHA256清单](../reports/wave_direction_20261127/manifest.json)。方向专项四组配置各跑五帧、正反两个实例，共40份240点输出；离线阶段未进行实屏或时序签核；后续构建/实屏结果单独记录于上述硬件证据。

- `scripts/run_display_prepare_sim.ps1`新增`tb_display_wave_direction`。四组配置为线性/带限插值分别搭配对齐关闭/开启。每组使用独立正反向Renderer和不同背压，比较全部240点的倒序等价性、轴幅度、对齐结果、频率、截断状态及帧号。使用非对称三分量波形测试1T/3T，再去掉基波检验真实低置信度回退，最后测试无效帧。断言覆盖停顿期间数据保持、递增序号、完整点数及完成时机。屏幕模型按`physical_x=W-1-s`放置点，该模型验证方向补偿数学关系，不替代实屏验收。
- `scripts/run_display_hmi_sim.ps1`的独立UART黄金模型按新方向计算期望样点，正反两种参数均检查完整命令、240点、结束符、HOLD、复位、页面刷新及STOP之后释放。
- `scripts/run_measurement_debug_sim.ps1`检查调试快照及真实顶层连接，DSP/IP使用原有黑盒契约，不能作为真实IP或实现时序的签核。

## 上板核对

用户重新综合、实现并检查资源、WNS/WHS和DRC，再生成并下载匹配bit/LTX。暂不把旧MCS或Release中的bit视为包含此修改。

用有非零相对相位的非对称复合波形，比较GUI与实屏1T/3T中峰谷的时间先后。允许触发起点不同带来的水平平移，模拟链路也可能改变分量相位；不以逐像素重合作为唯一标准。保持FFT页低频在左。若以后屏幕改为与逻辑时间同向落点，设`DISPLAY_WAVE_REVERSE_X=0`，避免两端重复补偿。
