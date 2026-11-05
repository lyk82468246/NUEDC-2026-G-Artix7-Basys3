# 标定保存、冷启动与配置升级实板验收

2026-11-05，用户在Vivado控制台逐步执行并回传结果；本记录不冒充自动测试。程序为11月5日22:27版本，时序WNS +0.317 ns、WHS +0.027 ns。镜像审计清单见[SHA256与地址范围](../display_scan_timing_20261105/p2_boot_01.audit.json)。

## 验收结果

原始活动bank：enabled=1、Vpp=3623460、RMS=3701829、FFT=4194（Q16.16 µV/raw，FFT为正弦峰值）；97位打包十进制`79295003553561560439932850274`。

| 测试 | 用户回传证据 |
| --- | --- |
| 首次保存 | SAVED_AND_VERIFIED；A槽source1、sequence0、saved_epoch1、error0、dirty0 |
| 相同bank再次保存 | UNCHANGED；槽位、sequence、saved_epoch未变；未独立探测SPI擦写指令，免擦写分支另有仿真断言 |
| 临时apply后reload | Vpp临时改1811730，epoch2、dirty1；reload恢复原bank，epoch3、dirty0；未改写保存记录 |
| 临时apply后BtnC | apply epoch4；按复位后原bank、epoch1、error0、dirty0 |
| 重新下载bit | 原bank、epoch1、A槽有效、error0、dirty0 |
| 断电再上电并手动下载 | 原bank、A槽有效、error0、dirty0，记录跨断电保留 |
| 配置镜像写入 | 用户报告烧写成功，器件profile为mx25l3273f-spi-x1_x2_x4（本机表包含mx25l3233f别名），文件p2_boot_01.mcs，ADDRESS_RANGE读回use_file，Erase/Program/Verify=1 |
| 配置Flash冷启动后恢复 | 用户报告重新上电启动；连接后识别1 ILA、2 VIO，无LTX不匹配；原bank、epoch1、A槽sequence0/saved_epoch1、ready1、error0、dirty0 |

最后一次完整状态摘录：

```text
rc_store::active
bank 79295003553561560439932850274 epoch 1 flags 131
rc_store_status
stage PERSISTENT busy 0 ready 1 saved_valid 1 source 1 error 0 ack 0 initialized 1 dirty 0 saving 0 apply_block 0 rejected 0 panel_pending 0 status_register 0 security_register 0 jedec 12722198 sequence 0 saved_epoch 1 bank 79295003553561560439932850274
```

因此已验证本次程序镜像升级后A槽标定记录仍存在并被应用。冷启动结论依赖用户执行既定断电上电流程，不包含电源波形或启动时间测量。

## VIO缓存警告的处理

重新上电后出现Labtools 27-1952：电脑缓存OUTPUT_VALUE与硬件VIO输出不一致。此警告不同于此前LTX核UUID/端口不匹配；应以硬件为准刷新：

```tcl
foreach core [get_hw_vios] {
    refresh_hw_vio -update_output_values $core
}
```

不使用Commit旧缓存或Reset VIO Outputs来消除此警告，以免旧request toggle成为新命令。上述刷新不提交输出。

## 尚未实板覆盖

B槽轮换保存、序号回绕、擦写中真实掉电、保护/损坏/陌生扇区拒绝仅由离线模型与RTL仿真验证；此次成功不能代替这些实板测试。保存系数仍按信号源设置值标定，独立绝对电压精度没有因此通过。波形、谐波及比赛指标的验收另行开展。
