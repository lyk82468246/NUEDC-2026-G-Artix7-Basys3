# 文档导航

先读[项目总览](../README.md)，确认[当前版本、系数与验证状态](project_status.md)，再按任务选择下表。日期型报告是实验快照，不能把“当时待构建”当作当前状态。

## 日常操作

| 任务 | 入口 |
| --- | --- |
| 接线、开关、LED、数码管、系统架构 | [项目总览](../README.md) |
| 比赛现场完整流程 | [验收操作手册](contest_acceptance_runbook.md)、[空白记录表](contest_acceptance_record_template.md) |
| 手动综合/实现、bit/LTX、MCS升级 | [Vivado手动工作流](manual_vivado_workflow.md) |
| 在线标定、保存与恢复 | [标定操作指南](runtime_calibration.md)、[参数Flash机制](flash_calibration_persistence_20261030.md) |
| ILA捕获、候选与有效性、故障码 | [当前ILA指南](ila_diagnostics.md) |
| 屏幕接口 | [屏幕spec](TJC_UART_FORMAT.md)、[显示集成契约](display_integration_20261029.md)；最终控件/尺寸需与实际工程核对 |
| AFG1022控制 | [脚本](afg1022_automation.md)、[GUI](afg1022_gui.md)、[组合波配方](afg1022_acceptance_waveforms.md) |

## 设计与复现

| 主题 | 文档 |
| --- | --- |
| 赛题与执行范围 | [原题](requirements/2026年G题.md)、[执行计划](contest_execution_plan.md)、[模型](contest_model.md) |
| ADC/FIR/时域、FFT/IP | [采集与时域](CAPTURE_CALC.md)、[频域与UART设计](FFT_UART.md)；早期设计说明结合当前RTL/XCI使用 |
| Flash格式与实现 | [格式1](flash_calibration_format_v1.md)、[P2机制](flash_calibration_persistence_20261030.md) |
| 仿真入口 | [总览中的回归命令](../README.md#仿真与自动化)及各专项报告 |
| 其他仪器 | [HDS242S](hds242s_automation.md)、[UTG932](utg932_automation.md)、[自动化API](lab_api.md) |

## 实验与修订证据

| 主题 | 最近证据 | 历史对照 |
| --- | --- | --- |
| 程序与镜像 | [11月6日MCS/时序](../reports/boot_mcs_20261106/README.md) | [10月30日构建](build_verification_20261030.md) |
| 标定 | [AFG多点标定及B槽保存](../reports/afg_calibration_20261106/README.md) | [旧VIO验证](runtime_vio_hardware_20261023.md) |
| Flash恢复 | [11月5日A槽恢复](../reports/flash_persistence_20261105/README.md) | [格式/机制](flash_calibration_persistence_20261030.md) |
| 单音故障 | [BNC/SMA恢复复测](../reports/single_tone_reseat_20261106/README.md)、[修复前候选](../reports/single_tone_candidates_20261106/README.md) | [10月23日BNC接触恢复](bnc_recovery_20261023.md) |
| 窗ROM独立缺陷 | [真实IP及背压验证](../reports/fft_window_alignment_fix_20261106/README.md) | [离线频点审查](../reports/single_tone_grid_review_20261106/README.md) |
| 旧多音验证 | [三分量幅值](component_amplitudes_hardware_20261024.md)、[高频/相位](highband_multitone_hardware_20261024.md) | 不代替当前程序/标定的完整验收 |
| 显示修订过程 | [频谱轴/刷新](screen_axis_refresh_20261030.md)、[插值](waveform_interpolation_20261030.md)、[集成回归](../reports/display_integration_20261030/README.md) | 设计/仿真证据与实屏确认分开 |

`reports/`保存可追溯证据；`test_results/`和`G_FPGA.runs/`是本机生成目录。原始数据、历史结果不删除或改写为新结论。整理前的[在线标定原文](runtime_calibration_history_20261106.md)、[构建交接原文](manual_vivado_workflow_history_20261106.md)、[ILA原文](ila_diagnostics_history_20261106.md)仅作追溯，不作为日常步骤。
