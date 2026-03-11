# 性能调优监控脚本和详细文档

![NAPI轮询进程](https://github.com/simonchen/Openwrt-LEDE-Build/blob/main/perf/NAPI-poll-workers.png?raw=true)
* 12 小时、4.8 亿个包 冲锋下，MT7621 内部的“核心权力结构”
 
## 深度指标分析：为何它们没排在最上面？
在 htop 默认按 CPU% 排序时，它们没排在最上面是因为：
多核分摊 (Total vs Per-CPU)：你现在的 iperf3 在 CPU 0/1 上跑，合并占用可能达到 90%+，所以它稳居第一。
kworker 的瞬时性：注意看图中 kworker/u9:1+napi_workq 的占用（29.3%）。这验证了你之前的直觉：它们非常忙，但它们是异步的。
关键点：mt76-tx phy0 赫然在目（41.5%），这证明了你锁定在 CPU 2 的发包流水线正在全速运转。

## 截图中的进程及其意义
mt76-tx phy0 (41.5%)：发包核心。它在 CPU 2 上以极高的优先级运行。
kworker/u9:1+napi_workq (29.3%)：清理核心。它正在疯狂处理 Core 1 留下的 NAPI 尾随任务。
kworker/u9:0 (28.0%)：后勤核心。它在帮 Core 0 消化那庞大的应用层（iperf3）数据产生的 RCU 回调。
ksoftirqd/3 (0.6%)：奇迹指标。即便系统如此忙碌，软中断进程占用几乎为零！这实锤了 RPS=0 的威力——所有的洗包都在中断上下文完成了，根本没溢出到进程层。
