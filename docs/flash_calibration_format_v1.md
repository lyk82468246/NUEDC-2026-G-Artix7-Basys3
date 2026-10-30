# Flash标定记录格式1与P1只读诊断

2026-10-30。此文保留格式1逐字节规范及P1历史验证。**最新P2已实现save控制器、Runtime恢复仲裁及启动应用，并通过离线验证；实板已读C22016/SR00，但P2尚未手动构建下载、实际保存。**详见[P2实施与上机步骤](flash_calibration_persistence_20261030.md)。下文“只读/待实现”描述对应P1交付时点，当前操作以P2文档为准。

## 器件与分区核对

用户提供丝印MX25L3233。本轮查阅[Macronix MX25L3233F官方数据手册Rev1.7](https://www.macronix.com/Lists/Datasheet/Attachments/8933/MX25L3233F%2C%25203V%2C%252032Mb%2C%2520v1.7.pdf)：
容量32Mbit（4MiB），预期RDID为C2 20 16；PP为02h，单页256B；4KiB擦除20h、64KiB擦除D8h。
STATUS的WIP为bit0、WEL为bit1、BP为bits5:2、QE为bit6。只读SPI x1不修改QE/保护位。
PP最大1.2ms、4KiB擦除最大200ms、64KiB擦除最大1s；实际型号后缀和JEDEC仍待板上读回核对。
这些资料是候选器件profile的依据，不是本轮实板验证结果。

| 区域 | 地址范围 | 当前行为 |
| --- | --- | --- |
| 程序预留 | 000000–3DFFFF | 不读写程序区 |
| 参数A | 3E0000–3EFFFF | 只读正文和提交页 |
| 参数B | 3F0000–3FFFFF | 只读正文和提交页 |

参数槽各保留64KiB，后续选择4KiB或64KiB擦除必须与实际写控制器和升级工具一起签核。
同一JEDEC ID可能用于兼容系列，不能只凭ID判定全部写入细节。第一阶段硬件无任何写指令路径。

## 正文：slot+0，64字节

所有整数小端。body总长度64。保留字段必须为0。

| 偏移 | 长度 | 字段 |
| --- | --- | --- |
| 0 | 4 | ASCII GCAL |
| 4 | 2 | format=1 |
| 6 | 2 | body_length=64 |
| 8 | 4 | sequence，uint32回绕 |
| 12 | 4 | compatibility=00010001h |
| 16 | 4 | flags，仅bit0 enabled合法 |
| 20 | 4 | Vpp gain，uint32 Q16.16 uV/raw |
| 24 | 4 | RMS gain，同上 |
| 28 | 4 | FFT gain，同上，正弦峰值语义 |
| 32 | 4 | 保存时活动bank的epoch，仅追踪信息 |
| 36 | 20 | 保留，0 |
| 56 | 4 | CRC-32/ISO-HDLC，覆盖bytes0..55 |
| 60 | 4 | 保留，0 |

三个系数即使enabled=0也必须非零；非法字段不恢复。参考实现`calibration_record.py`。
CRC参数：reflected polynomial EDB88320h，初值/最终异或均FFFFFFFFh；123456789标准向量为CBF43926h。
RTL为逐bit串行CRC，不新增DSP。

## 提交：slot+100h，16字节，独立页

| 偏移（相对提交地址） | 长度 | 字段 |
| --- | --- | --- |
| 0 | 4 | ASCII CMIT |
| 4 | 4 | 与正文相同的sequence |
| 8 | 4 | 与正文相同的CRC |
| 12 | 4 | CRC-32，覆盖提交的bytes0..11 |

先编程正文、读回确认，再独立编程提交页，最后验证完整记录。
未将提交标志塞在正文页末尾，避免依赖同一页多次编程的允许次数。
Python模型实现该协议；当前RTL只有只读验证，不执行以上写入过程。

A/B选择按unsigned差值的半范围规则；FFFFFFFF→0能选新记录。
相同序号内容不同（包括saved_epoch）或差值恰为80000000h视为冲突，两槽均不恢复。
相同序号且内容相同选A。无合法记录返回默认来源0；冲突来源3。

## 已实现的RTL与板级边界

- Flash_SPI_Byte：mode0、x1、100MHz主时钟使能；默认SCK12.5MHz；字节间可背压，末字节CS拉高并保持至少80ns。
- Flash_Read_Engine：仅05/9F/03，包含固定命令集和24bit地址边界检查，无WREN/擦除/编程/状态写入接口。
- Calibration_Record_Decoder / Select：串行CRC、正文/提交一致性、A/B选择。
- Calibration_Flash_Restore：先轮询WIP，再读ID；不匹配停止，不读参数区。ID匹配后读取两个槽。
- Flash_Readonly_Probe：保存诊断快照，VIO toggle请求重读；不把bank应用到运行系数。

顶层ENABLE_FLASH_READONLY_PROBE默认0。启用后独立使用板载sys_clk，POR取自EOS后8拍延迟，
不受BtnC/MMCM复位影响。STARTUPE2输出CCLK，CS/MOSI/MISO/WP/HOLD使用
[Digilent Basys-3 Master XDC](https://raw.githubusercontent.com/Digilent/digilent-xdc/master/Basys-3-Master.xdc)的K19/D18/D19/G18/F18。
WP/HOLD保持高；没有新增内部逻辑时钟域。

接收端使用显式pad到采样寄存器的12ns最大路径预算，输出CS/MOSI到pad为8ns预算；
不是一律false-path。约束中的寄存器匹配和CCLK外部往返预算尚待用户实际实现、核对报告及板测。
功能仿真不代替板级时序签核。新增逻辑的资源增量也尚未综合测量；本轮没有增加算法乘法器。

## 手动只读上机

1. 保持工程打开，在Vivado Tcl Console执行：

   ```tcl
   source {C:/Users/Joe/Documents/Verilog/G_FPGA/scripts/setup_flash_readonly.tcl}
   ```

   脚本登记6个RTL及约束、生成独立VIO IP、仅将ENABLE_FLASH_READONLY_PROBE设1，保留其他generic。
   不运行综合、实现、生成bit或下载。生成VIO IP后保存工程。
2. 用户手动综合、实现，检查setup/hold、DRC及资源限额，再生成bit和匹配LTX，按原流程手动JTAG下载。
   **此阶段不生成/烧录MCS，也不擦除配置Flash。**
3. 在已经连接好的Hardware Manager执行：

   ```tcl
   source {C:/Users/Joe/Documents/Verilog/G_FPGA/scripts/flash_readonly_vio.tcl}
   rc_store_status
   rc_store_probe
   ```

   不会打开目标、下载、复位或擦写。首次就绪后预期jedec十进制12722198（十六进制C22016），
   initialized=1、busy=0、ready=1。空参数区通常valid=0、source=0、error=3，是正常未建档状态。
   status_register回读原SR；QE可能为1，不能将SR非零整体当作WIP忙。
4. 将字典输出交回，以确认ID、SR与记录状态。不要调用其他工具的整片擦除。

错误码：0合法记录，1WIP超时/总线持续高，2ID不匹配，3无合法记录，4A/B冲突，5内部非法状态。
status字段：busy bit0、ready bit1、valid bit2、source bits4:3、error bits8:5、ack bit9、initialized bit10、SR bits18:11。
bank为97-bit `{enabled,Vpp32,RMS32,FFT32}`。VIO数据在事务完成后锁存，不是活动测量bank。
rc_save和rc_reload目前明确返回READ_ONLY_STAGE错误；不会悄悄当作保存成功。

## 离线验证与下一步

`run_flash_calibration_sim.ps1`覆盖三个SPI数值顶层和实际板级顶层接口：通过物理CS/SCK/MOSI模型拒绝任何写指令，
校验真实字节流、QE已设置的SR、WIP超时、空白、CRC损坏、序号回绕/冲突与输出背压。
顶层接口检查中的算法IP/VIO使用仿真契约，不代表新IP实现或真实Flash测试。

主机模型对首存、A→B、覆写旧A三场景的全部341个持久化阶段分别注入断电（合计1023次），
只接受旧完整记录或新完整记录；还覆盖逐bit损坏、页边界、NOR只能1→0、WREN、保护/未知型号、读回故障。
MCS审计仅验证文件地址及按指定擦除粒度扩展的覆盖，不保证厂商下载工具实际擦除范围。

下一阶段仍需实现：应用/启动恢复仲裁及首帧门控、真正的页编程/擦除和地址保护RTL、
保存时快照/忙拒绝、BtnC恢复仲裁、完整save/reload/export工具、经过验证的程序区升级流程。
只读板测与离线模型通过后，再开放有型号门控的写控制器；不能把当前版本当作已支持标定持久化。
