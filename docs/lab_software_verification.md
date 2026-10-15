# 自动化脚本软件验证记录

日期：2026-10-15（Asia/Shanghai）。环境：Windows、Python 3.12、项目独立虚拟环境 `.venv-hds`。

本轮只做软件和模拟验证，不连接真实 HDS242S、不启用真实发生器、不下载 FPGA bitstream、不运行综合/实现。先前真实 USB 识别与固件单位验证属于上一阶段，见 [HDS242S 指南](hds242s_automation.md)。

## 回归结果

运行：

```powershell
.\.venv-hds\Scripts\python.exe -m unittest discover -s scripts/instruments -p 'test_*.py' -v
```

结果：31 项测试通过。测试文件为 `scripts/instruments/test_hds242s.py` 和 `scripts/instruments/test_lab.py`。

| 验证范围 | 覆盖内容 |
| --- | --- |
| USB 协议 | 文本/二进制分包、长度前缀、数据内 LF 字节、异常后会话失效、写失败 |
| 命令配对 | 8 线程发起 16 次查询，保持 write/read 成对串行，无交叉响应 |
| 固件与计划 | µHz/mV 换算、非零偏置拒绝、频率/幅值/电压极值限制、NaN 拒绝 |
| FPGA 数据 | ILA radix 解析、只选 measurement_valid 有效样本、失败不冒充结果 |
| 跨进程独占 | 第二进程不能取得已占用的 OS 锁，释放后可重新取得 |
| 状态维护 | 启动状态 unknown、外部模拟面板改动后验证失效、观测过期标记 |
| 异步任务 | 有界队列、排队/运行中取消、运行中并发状态查询 |
| 停止输出 | 满队列时仍可停止，取消待执行 ON，失败 OFF 记 unknown |
| 断线与恢复 | 模拟超时使观测失效，显式重连后重新核验，不重放输出命令 |
| 错误隔离 | FPGA/Vivado 失败不误标为 USB 仪器断线 |
| 进程清理 | 使用测试自身创建的等待子进程，验证取消/超时后被回收；不运行真实 Vivado |
| 结果一致性 | 采集期间发生器设置变化时拒绝结果；未确认计划不执行参数设置 |
| 文件与关闭 | 状态 JSON 可读、任务终态持久化、关闭后队列为零且无 active_job |
| HTTP/客户端 | 本地令牌、异步任务、幂等键、客户端等待超时不自动取消、显式取消 |

本机受限执行环境不允许普通沙箱访问回环网络及部分系统临时目录，因此完整测试在获准的沙箱外执行；测试依然只使用模拟端点。

## 集成演示

运行 `scripts/instruments/lab_demo.py`，通过真实本地 HTTP 客户端/服务交互，完成 50/100/200 kHz 三点、每点两次，共 6 次模拟 FPGA 采集，输出关闭并正常退出。逐次 `result.json`、索引、任务及状态文件位于本机 `test_results/20261015_230855_636193/`，均标记 simulated。该目录不提交到 Git，不能视为真实板测数据。

另行启动 `lab_server.py --mode simulate --port 0`，通过独立命令行客户端依次查询 status、submit connect、jobs、shutdown；服务正常退出，持久状态为 stopped、output=off。验证结束没有保留后台模拟服务。

## 尚需硬件验证

真实接线后的输出电压/负载含义、FPGA JTAG 与 bit/ltx 匹配、实际 ILA CSV 格式、USB 拔插恢复、长时间稳定性仍待测。锁约束本仓库程序，不能代替关闭厂家软件；状态轮询不能捕获两次查询间出现又消失的面板变化。非零偏置依然未实现。软件测试通过不代表模拟测量精度达标。
