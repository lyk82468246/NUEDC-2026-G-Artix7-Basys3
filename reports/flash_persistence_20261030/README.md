# P2离线签核与P1实板读回

2026-10-30。此报告不代表P2已通过综合、布局布线或实板写入。

## 实板只读证据

已下载的15:39:25产物SHA256：

```text
G_FPGA_Top.bit 1AB2A6C16F5EE911A3827CC1A2A12FDBFF28952304ED1CA3468A4D104E4EC96B
debug_nets.ltx B7662C8ADDE0169562985723DFA2DF35D034E2E3190BCB7E92B1328569A3BF49
```

两次独占JTAG查询结果（后一次触发新的物理SPI读取）：

```text
action flash_status flash {stage READ_ONLY busy 0 ready 1 valid 0 source 0 error 3 ack 0 initialized 1 status_register 0 jedec 12722198 sequence 0 saved_epoch 0 bank 0}
action flash_probe flash {stage READ_ONLY busy 0 ready 1 valid 0 source 0 error 3 ack 1 initialized 1 status_register 0 jedec 12722198 sequence 0 saved_epoch 0 bank 0}
```

无有效记录；不证明整个保留区为空。本轮硬件操作没有写Flash、apply、复位或下载。

## 离线结果

Windows Vivado 2025.2 XSim，`scripts/run_calibration_store_sim.ps1`全部PASS：

| 顶层 | 核验内容 |
| --- | --- |
| tb_calibration_store | SPI线级NOR、A/B保存、提交前后掉电、BtnC、回绕、保护、失败与回读验证 |
| tb_flash_command_guard | 未验证profile、程序区、页界限、越界与非法命令均在拉低CS前拒绝 |
| tb_calibration_encoder | 正文与提交80字节逐字节匹配Python黄金向量 |
| tb_runtime_restore_atomic | 包间提交、sample优先、epoch原子性、阻止旧VIO请求重放 |
| flash_persistent_top_contract | 实际顶层接线、首次采集和重载门控、BtnC不停止Flash时钟/POR |

原`run_flash_calibration_sim.ps1`与`run_measurement_debug_sim.ps1`通过，旧运行时标定仿真通过。顶层算法IP为黑盒，仅验证接口和控制契约。

`.venv-hds/Scripts/python.exe -m unittest discover -s scripts/instruments -p test_*.py`：147 tests，OK。包含其他仪器原有测试，不表示147项均是本轮新增测试。

完整本地日志位于忽略的`test_results/calibration_store_sim`、`flash_calibration_sim`、`measurement_debug_sim`、`runtime_calibration_sim`。P2资源、时序、DRC与实际save/冷启动均待用户手动构建及下一轮验收，流程见[实施文档](../../docs/flash_calibration_persistence_20261030.md)。
