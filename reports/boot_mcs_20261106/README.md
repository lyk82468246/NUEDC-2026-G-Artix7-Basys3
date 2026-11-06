# 新启动镜像生成记录（2026-11-06）

仅离线生成、未连接或烧写Flash。沿用scripts/create_boot_mcs.tcl，Vivado 2025.2 write_cfgmem及python -E强制地址审计均成功，0错误/警告。

- 输出：test_results/p2_boot_20261106_romfix_e733a9e.mcs（本地生成产物，按仓库规则忽略）
- 输入：G_FPGA.runs/impl_1/G_FPGA_Top.bit，2026-11-06 08:33:21；包含e733a9e窗ROM读取修订，schema3原始候选诊断。
- 输入匹配LTX：G_FPGA.runs/impl_1/debug_nets.ltx，08:33:22。
- 当前实现报告：08:32:08，WNS +0.280ns、WHS +0.011ns、TNS/THS 0，约束满足；本轮未执行综合/实现。
- SPIx1，4MiB，从0地址加载；实际数据末地址0x1C5E7F，按64KiB对齐擦除覆盖至0x1D0000（不含），未进入参数起点0x3E0000。
- image.audit.json记录MCS/bit SHA256；MCS文件生成不代表实际Flash内容已更新。

用户手动烧写时使用PROGRAM.ADDRESS_RANGE=use_file，禁止整片擦除，保留0x3E0000～0x3FFFFF。地址审计不替代编程器擦除策略确认；烧写后核对保存系数并验证冷启动。
