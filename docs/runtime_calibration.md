# 在线标定、保存与恢复

适用当前P2程序；版本与实际系数见[当前状态](project_status.md)。当前已有VIO与参数Flash功能，不需要再次安装IP或重新构建。

## 系数和参考

| 输出 | 当前活动/保存系数 | RTL回退默认系数 |
| --- | ---: | ---: |
| Vpp / 显示Amax | 3576768 | 3623460 |
| 真RMS | 3601627 | 3701829 |
| FFT各正弦分量峰值 | 4079 | 4194 |

单位为unsigned Q16.16 µV/raw：`µV = saturate_uint32((raw × gain + 32768) >> 16)`。RMS由时域平方均值计算，标定实验中的理想正弦参考才使用Vpp/(2√2)。FFT参考为Vpp/2，不能把同一个Vpp系数套给FFT。

本次标定以AFG1022 HIGHZ显示设定值为参考，包含负载和模拟链路的等效比例；不是端口独立绝对电压计量。换源负载设置、接线、前端、ADC配置或FIR后需复核。[拟合、独立验证、175mVpp实际输出及保存证据](../reports/afg_calibration_20261106/README.md)已归档。

## apply、save、reload分别做什么

| 操作 | 作用 |
| --- | --- |
| `rc_apply` | 原子更新活动bank并增加epoch，不写Flash |
| `rc_save` | 保存已应用bank；回读验证；相同bank返回UNCHANGED，不重复擦写 |
| `rc_reload` | 重新读Flash并应用有效记录，覆盖未保存的在线值 |
| 启动/BtnC | P2先恢复有效保存记录，再放行采集；没有有效记录才回退RTL默认值 |
| `rc_export` | 导出已解码的活动/保存系数与元数据，不是原始Flash转储 |

当前B槽sequence1、saved_epoch2已保存核对。本轮未做新B槽断电恢复；恢复后活动epoch不要求等于saved_epoch。VIO的暂存/request可能跨BtnC保留，RTL不会因此自动重新提交旧暂存值。

## 当前GUI连接中的操作

使用与程序匹配的`debug_nets.ltx`，只保留一个JTAG操作者，停止其他自动捕获任务。以下命令在已连接目标的Vivado Tcl Console执行，不会编译或下载程序：

```tcl
source C:/Users/Joe/Documents/Verilog/G_FPGA/scripts/flash_store_vio.tcl
rc_store_status
rc_store::active
rc_read
```

`rc_read`单位是µV；只有valid=1、result_epoch匹配，且result_count相对上次增加，才是新有效结果。源OFF时无效/零输出正常，不能用来标定。

已验证系数的在线应用示例（这是写操作，正常启动无需重复执行）：

```tcl
rc_apply 3576768 3601627 4079 1
rc_store::active
rc_read
```

先设置新源输入并验证新结果，再选择是否持久化：

```tcl
rc_save
# 需要SAVED_AND_VERIFIED；若bank已相同，UNCHANGED也正常
rc_store_status
rc_export C:/Users/Joe/Documents/Verilog/G_FPGA/test_results/calibration_export_new.json ROMFIX-20261106
```

导出使用新文件名。回退到已保存值使用`rc_reload`；不是回退到RTL默认值。禁用活动标定可用`rc_apply 0 0 0 0`，会改变显示有效性，不是普通检查步骤。

## 独占命令行入口

在仓库根目录PowerShell运行；directory必须尚不存在。以下仅查询：

```powershell
.\.venv-hds\Scripts\python.exe -E scripts/instruments/runtime_vio.py store_status `
  --ltx G_FPGA.runs/impl_1/debug_nets.ltx --directory test_results/calibration_status_new
```

同一入口支持inspect/read/apply/store_save/store_reload/store_export。脚本持有JTAG锁，超时不自动重放未知写操作；先只读核对状态、bank和序号，再处理。

## 标定流程与判据

1. 源OFF时锁紧BNC/SMA，确认供电/共地、HIGHZ、CW、0V偏置。约189～192kHz背景有两次接触故障历史，优先复查连接。
2. 在已确认量程内取多个幅值；每个点校验源前后回读、频率、一个新ILA事件、信号有效和候选数。拒绝旧帧、错误设置及受杂散污染点。
3. 分别对Vpp/RMS/FFT作过原点拟合；自由截距仅诊断，不擅自从任意波形减去常数。
4. 用未参与拟合的幅值验证，再用实际VIO换算输出验证；训练残差不是精度认证。
5. 在线apply后核对活动值、epoch和新有效包，再save并导出。需要时另做断电恢复和多音/频带检查。

不需要为更新系数重综合或生成MCS。新系数在参数Flash中，程序镜像升级必须保留该区。记录格式、保护和错误码见[Flash机制](flash_calibration_persistence_20261030.md)。旧实验与最初安装步骤见[历史原文](runtime_calibration_history_20261106.md)。
