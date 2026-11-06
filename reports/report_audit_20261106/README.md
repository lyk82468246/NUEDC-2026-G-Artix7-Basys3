# 2026-11-06报告素材离线审计证据

仅复制/读取已有文件，无Vivado构建或硬件访问。设备均已脱机。

本目录归档11月6日同轮placed资源报告（08:28:08）、routed时序（08:32:08）、routed DRC（08:31:19）、methodology（08:31:58）和route status（08:32:09），不把不同版本结果混合。placed资源不是声称另跑了post-route utilization。manifest.json记录原始文件哈希、bit/LTX/MCS哈希、源码比对及明确标为设计推导的FIR/模拟信息。

完整可独立阅读的事实、实验、待测表及图稿见[报告素材](../../docs/report_materials_2026-11-06.md)。模拟图纸原附件及渲染图只留本地忽略目录test_results/report_audit_20261106/，未获得明确远程发布授权，不随本次提交外发；来源hash见manifest。元件关系与理想推导已在报告素材中完整记述。图纸不证明实焊值及整个ADC模块前端。

用户随后明确授权以非二进制格式重画并上传，已据本地图纸重绘[SVG](../../docs/report_assets_20261106/analog_frontend_schematic.svg)及[文字连接表](../../docs/report_assets_20261106/analog_frontend_schematic.md)，仅提交XML矢量源，不嵌入原PDF/PNG或外部资源。已本地渲染核对电路与文字位置，预览位图仅留test_results。

本目录.gitattributes仅对原始.rpt关闭换行转换并容许Vivado生成的行尾对齐空格，保持manifest哈希可复核；Markdown/SVG仍按通常格式检查。
