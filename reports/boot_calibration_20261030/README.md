# RTL 上电默认标定回归（2026-10-30）

默认值来自已实测存档：Vpp=3623460、RMS=3701829、FFT=4194，Q16.16发生器HIGHZ设定参考µV/raw。板级默认启用，epoch=0；不表示独立绝对输入电压校准。

| 日志 | 结果 |
| --- | --- |
| runtime.log | 三个XSim顶层通过：显式禁用默认bank、实测默认bank启用、零增益默认bank拒绝。验证首帧无需VIO提交、无隐式零暂存覆盖、原子在线更新、复位恢复默认、保留request=1不重放旧提交、复位后新提交有效、舍入/饱和/无信号/overrun |
| top.log | 两个XSim顶层通过：同帧ILA快照/校准提交碰撞；实际板级VIO开关、新旧显示分支、默认参数传递、默认bank禁用选项、显示busy抑制AFE许可。厂商DSP仍为黑盒，不是全DSP数值验证 |
| host.log | 110项离线主机/拟合/Tcl注册/ILA解码测试通过，无硬件连接 |

复现：`scripts/run_runtime_calibration_sim.ps1`、`scripts/run_measurement_debug_sim.ps1`及主机unittest discover。首次host提交需要在复位后3拍同步完成之后发起；实际JTAG提交远慢于此窗口。ILA位宽不改，metadata bit1与VIO存在bit2独立。

没有IP生成、综合、实现、bit生成、烧写或仪器访问。VIO IP暂存初始化保持原配置，只修改RTL活动bank复位值和请求重同步；旧bit/旧Flash镜像不会自动包含本次默认值。
