# 性能调优监控脚本和详细文档

## MT7915 硬中断的职责
*1. CPU3 (MT7915e IRQ 25)：无线接入的“守门员” (Rx & Interrupt)*
- CPU3 承载的是 MT7915 的物理层硬中断。它的任务是“最脏、最快、实时性最高”的：
Rx 数据接收 (DMA 搬运)：当 MT7915 硬件 Buffer 收到空中的无线包时，会触发 IRQ 31。CPU3 必须立即响应，将数据包从 WiFi 芯片的内存通过 PCIe 总线搬运到主内存（DDR）中，并封装成 sk_buff 结构。
- ACK 响应控制 (SIFS 时间窗)：WiFi 协议要求在极短的时间内回复 Block Ack。如果 CPU3 忙于其他事务（如 RPS 洗包），响应变慢，对端就会认为丢包，从而触发 BA MISS。
NAPI 轮询调度：CPU3 负责执行 mt76_poll。它就像一个高速旋转的转子，不停地检查硬件 Ring Buffer，确保缓冲区不溢出。
- 信标 (Beacon) 与同步：维持与中继上级的时钟同步。
当前状态总结： 你之前看到的 91.2% 负载，主要就是 CPU3 在疯狂搬运数据包。如果它慢了，整个链路就会断流。
*CPU2 (MT7915e-hif / mt76-tx)：无线发送的“排队调度员” (Tx Logic)*
- CPU2 运行的是驱动层的 发送工作队列。虽然发送动作最终由硬件完成，但“发什么、怎么发”全靠 CPU2：
- 聚合帧构造 (A-MPDU/A-MSDU)：这是最耗 CPU 的地方。你限制了 MSDU=3，CPU2 就要负责把内存里零散的小包，按照 M3 的规格“打包”成一个巨大的聚合帧。
- Tx 描述符管理：为每个要发送的包分配 DMA 描述符，告诉硬件这些包在内存的什么位置。
- 拥塞算法反馈 (Cubic/BBR)：你现在切到了 Cubic，CPU2 就要根据丢包和 RTT 情况，计算当前的 发送窗口 (CWND)。如果窗口缩了，CPU2 就得把包压在队列里不发。
- 重传逻辑处理：当 CPU3 收到对端的“丢包报告”后，会通知 CPU2，CPU2 负责从重传队列里找出那个包，重新塞进发送 Ring Buffer。
- CPU2 是你的“弹药调度中心”。如果 CPU2 慢了，WiFi 发送就会“卡顿”，表现为吞吐量曲线出现锯齿。
 
## 深度指标分析：为何它们没排在最上面？
<img src="https://github.com/simonchen/Openwrt-LEDE-Build/blob/main/perf/NAPI-poll-workers.png?raw=true" width="70%" height="70%">

**12 小时、4.8 亿个包 冲锋下，MT7621 内部的核心权力结构**
在 htop 默认按 CPU% 排序时，它们没排在最上面是因为：
多核分摊 (Total vs Per-CPU)：你现在的 iperf3 在 CPU 0/1 上跑，合并占用可能达到 90%+，所以它稳居第一。
kworker 的瞬时性：注意看图中 kworker/u9:1+napi_workq 的占用（29.3%）。这验证了你之前的直觉：它们非常忙，但它们是异步的。
关键点：mt76-tx phy0 赫然在目（41.5%），这证明了你锁定在 CPU 2 的发包流水线正在全速运转。

## 截图中的进程及其意义
mt76-tx phy0 (41.5%)：发包核心。它在 CPU 2 上以极高的优先级运行。
kworker/u9:1+napi_workq (29.3%)：清理核心。它正在疯狂处理 Core 1 留下的 NAPI 尾随任务。
kworker/u9:0 (28.0%)：后勤核心。它在帮 Core 0 消化那庞大的应用层（iperf3）数据产生的 RCU 回调。
ksoftirqd/3 (0.6%)：奇迹指标。即便系统如此忙碌，软中断进程占用几乎为零！这实锤了 RPS=0 的威力——所有的洗包都在中断上下文完成了，根本没溢出到进程层。

## 基于 RT 优先级隔离与 NAPI 异步分流的 MIPS 极限稳态研究
CPU 3 (RPS=0)：在前线拼命收割（NAPI）。

u9:1+napi_workq：在后方打扫战场（洗包）。

CPU 2 (mt76-tx)：在隔壁全速发车（填包）。

migration/2：在门口站岗，确保没人敢乱闯 CPU 2 的领地。

Softnet >Squeeze 始终为０ (５亿包处理）

这套“影子政府”般的内核架构，是 MT7621 冲击 300M+ 稳态的终极秘密。

## Sysctl.conf 深度调优（针对BBR算法的内存管理和延迟计算方法）
```
# BBR Memory & Pacing Stabilization
# Use BBR for balanced CPU/throughput
net.ipv4.tcp_congestion_control = bbr
# CRITICAL: Limits local buffer bloat; prevents Order-0 memory depletion and CPU3 "drowning"
net.ipv4.tcp_notsent_lowat = 16384
# Reduces RTT memory from 300s to 5s; stops the "permanent slowdown" caused by transient CPU jitters
net.ipv4.tcp_min_rtt_wlen=5
# Dampens the "Startup" burst from 200% to 150%; prevents instant reboot due to skb allocation spikes
net.ipv4.tcp_pacing_ss_ratio=150
# Disables slow-start restart after idle; maintains peak rate after short transmission gaps
net.ipv4.tcp_slow_start_after_idle=0
# Enables RACK (Recent ACK); essential for WiFi environments to handle packet reordering without dropping rate
net.ipv4.tcp_recovery=3

# Net core and CPU protection
# Balanced budget for NAPI polling; ensures enough packets are processed per cycle
net.core.netdev_budget=300
# 20ms window; allows CPU3 enough time to handle fragmented memory without context switch thrashing
net.core.netdev_budget_usecs=20000
# Increases input queue depth; provides a safety buffer for BBR's "in-flight" packets during CPU spikes
net.core.netdev_max_backlog=5000
# Disable timestamping to save CPU3 cycles
net.core.netdev_tstamp_prequeue = 0

# Basic memory and net core config
vm.min_free_kbytes=16384
#fs.file-max = 51200
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.somaxconn = 4096
net.core.rps_sock_flow_entries = 4096

net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_tw_recycle = 0
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 600
net.ipv4.ip_local_port_range = 10000 65000
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_max_tw_buckets = 16384
net.ipv4.tcp_rmem = 4096 87380 8388608
net.ipv4.tcp_wmem = 4096 65536 8388608
```

## /proc/pagetypeinfo 中的奥秘
### sysctl.conf 调优前的内存分布 (15小时高压测试后)
```
cat /proc/pagetypeinfo
Page block order: 10
Pages per block: 1024

Free pages count per migrate type at order 0 1 2 3 4 5 6 7 8 9 10

Node 0, zone Normal, type Unmovable 9 40 42 2 11 4 0 2 1 1 3

Node 0, zone Normal, type Movable 71 461 316 97 33 6 3 2 2 1 4

Node 0, zone Normal, type Reclaimable 3 1 20 3 1 0 1 0 0 1 0

Node 0, zone Normal, type HighAtomic 0 0 0 0 0 0 0 0 0 0 0

Number of blocks type Unmovable Movable Reclaimable HighAtomic

Node 0, zone Normal 22 39 3 0
```
- 核心危机：高阶连续页（High-Order Pages）几乎耗尽
Order 5-9 的枯竭：看 Movable（可移动）这一行，从 Order 5 开始，可用块仅剩个位数（6, 3, 2, 2, 1）。
后果：在 MSDU=3 的聚合下，驱动层和网络协议栈申请大块连续内存（例如用于接收环形缓冲区的 kmalloc）时，内核已经找不到现成的连续物理页了。
连锁反应：此时内核会频繁触发 Lumpy Reclaim（碎片整理），这会直接抢占 CPU0/1 的周期，导致你观察到的 Load 4.91 居高不下。

- 关键瓶颈：Unmovable（不可移动）页的分布
分析：Unmovable 在 Order 10 还有 3 个块，但在 Order 6-7 却是 0 或 2。
风险：内核的核心组件（如驱动申请的 DMA 内存）通常申请 Unmovable 内存。如果 Order 6/7 彻底断流，一旦驱动尝试重新初始化或申请新的 Buffer，系统会直接卡死或报 page allocation failure。

- Reclaimable（可回收）几乎为零
分析：这一行全是 0, 1, 3 这样的小数。
解读：这说明你的 vfs_cache_pressure（文件缓存压力）已经把磁盘缓存挤压到了极致，内存中几乎没有任何可以轻易置换出来的“软空间”了。现在的 56MB 空闲内存全是实打实的“死钱”，腾挪空间极小。

- HighAtomic（紧急备用金）为零
解读：HighAtomic 这一行全 0 是最危险的信号。在网络高压下，当普通申请失败时，内核会尝试从这个“紧急池”里拿内存。现在这里没钱了，意味着下一次大包申请一旦失败，就是直接丢包（BA MISS 爆发）或进程挂起。

### 某次用 ``` echo 1 > /proc/sys/vm/compact_memory ```紧缩内存后
```
cat /proc/pagetypeinfo
Page block order: 10
Pages per block:  1024

Free pages count per migrate type at order       0      1      2      3      4      5      6      7      8      9     10
Node    0, zone   Normal, type    Unmovable     45     77     67      9      5      3      3      1      3      0      3
Node    0, zone   Normal, type      Movable     11     15      4      3      2      1      1     12     11      7      9
Node    0, zone   Normal, type  Reclaimable     17     40     31      6      1      0      1      0      0      1      0
Node    0, zone   Normal, type   HighAtomic      0      0      0      0      0      0      0      0      0      0      0

Number of blocks type     Unmovable      Movable  Reclaimable   HighAtomic
Node 0, zone   Normal           22           39            3            0
```
Movable区域，虽有改善可连续order 10 (4MB) 内存块数增多，但是，order 0 数字很小，表明skb内存不释放，可能长期被占据。
- 元凶是系统默认 ```net.ipv4.tcp_notsent_lowat=4294967295```
**1. 为什么这个参数会“吃掉”你的 Order-0 内存？**
内存堆积机制：BBR 为了探测带宽，会尽可能多地把数据包塞进发送缓冲区。当 ```tcp_notsent_lowat``` 无限制时，内核会允许 BBR 在内存中积压海量尚未发出的 sk_buff（每个包都占用大量的 Unmovable 和 Order-0 内存）。
碎片化诱因：这几百兆的“待发包”会瞬间占满 SLAB 分配器。当驱动（mt76 on IRQ25 CPU3）急需一个内存描述符来处理收到的 ACK 时，发现内存全被这些“还没发出去的包”占满了，于是触发 direct reclaim（直接回收）。
后果：这就是你看到的 Order-0 瞬间枯竭，CPU3 随即陷入“搬运这些无意义积压包”的无效劳动中，最终导致崩溃。
**2. 为什么它会让 BBR “逻辑混乱”？**
缓冲区膨胀 (Bufferbloat)：大量数据堆积在本地内存而非物理链路中，会导致 RTT 采样包含了“在内核排队的时间”。
伪延迟：BBR 采样到了这个由于“内存挤压”产生的延迟，误以为是网络拥塞，于是触发了那个 300秒的长记忆减速循环。

### sysctl.conf 调优后的内存分布 (TODO: 运行初期）
```
cat /proc/pagetypeinfo
Page block order: 10
Pages per block:  1024

Free pages count per migrate type at order       0      1      2      3      4      5      6      7      8      9     10
Node    0, zone   Normal, type    Unmovable    129    161    138     12      3      0      2      0      1      1      0
Node    0, zone   Normal, type      Movable    347    451    204     50     10      1      1      1      1      0     12
Node    0, zone   Normal, type  Reclaimable     12     53     36     11      0      0      0      0      0      1      0
Node    0, zone   Normal, type   HighAtomic      0      0      0      0      0      0      0      0      0      0      0

Number of blocks type     Unmovable      Movable  Reclaimable   HighAtomic
Node 0, zone   Normal           19           42            3            0
```
连续 Movable 4MB (order 10) 内存有12个， order 0 有347个， 表明回收顺畅，可用大块内存充足，系统适合长跑。
长跑过程中，如有发现order 0不释放，内存又需要再分配(skb都是小包压在order 0-4)，可向其它order 5-9申请，除非order 5-9耗尽，
但只要order 10仍有盈余，就能保证系统长跑时间，这是回收、再分配内存的闭环，需要syctl.conf对net.core / net.ipv4中对包管理的优化才能达到，
默认内核系统给的值都是针对大内存GB以上的默认值，不适合GB以下MB的小内存。
