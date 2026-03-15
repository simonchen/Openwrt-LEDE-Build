# MT7621 + MT7915性能调优监控和详细文档

## 环境与设定
- [MT7915 开源驱动](https://github.com/openwrt/mt76)
  - 基于2022年底版本加入几乎所有最新patches(除MT7621不支持wed)，加入针对WIFI5网卡优化的AMSDU聚合max.3限制
- 路由端 AP+CLIENT 5G 中继
- 电脑端 WIFI 5G 网卡，Windows 11命令行: iperf3 -R -P 1 -w 1M -t 72000 按20小时不间断压测
- 手工校正CPU各核的分工
  - CPU2: mt7915e 产生接收中断 - 产生napi schedule
  - CPU2: mt7915e-hif 处理 DMA 搬运 - 从环形缓冲区拿数据 
  - CPU2: 驱动级绑定 mt76-tx 处理发送逻辑 - 包聚合发送给电脑端 或上级ap
  - CPU0/1：napi-workq 进程 
- 连续6小时压测后的性能

  ![alt=连续6小时压测后的性能](300M.png)
  
**注1：**
<sub>更多压测性能分析依赖于对硬、软中断在各CPU核的分布，以及SLAB内存管理碎片化，详见后面</sub>

**注2：**
<sub>
iperf3 -w 参数的默认值 (https://serverfault.com/questions/777023/whats-the-default-tcp-window-size-of-iperf3)
iperf3 的 -w (Window Size) 默认值并不是一个固定常数，它取决于操作系统协议栈的实现：
Linux 系统： 通常默认在 256 KB 左右，但内核会根据 net.ipv4.tcp_rmem 和 tcp_wmem 的设置进行动态自动调优 (Autotuning)。
Windows 系统： 默认通常在 64 KB 左右，虽然 Windows 也有 Receive Window Auto-Tuning 机制，但在高吞吐（如 300M+）或高延迟环境下，手动指定 -w 1M 能显著提高稳定性，防止 Windows 的激进调优导致吞吐剧烈波动。
测试中手动锁定 -w 1M让发送端和接收端在 1MB 的水位上达成协议，避免了 MIPS 处理器频繁去处理窗口更新的计算开销。
</sub>

## MT7915 硬中断的职责 - 将所有MT7915e-hif / mac 硬中断全部绑定在CPU2的优势

*1. CPU2 (MT7915e IRQ 25)：无线接入的“守门员” (Rx & Interrupt)*
- CPU2 承载的是 MT7915 的物理层硬中断。它的任务是“最脏、最快、实时性最高”的：
Rx 数据接收 (DMA 搬运)：当 MT7915 硬件 Buffer 收到空中的无线包时，会触发 IRQ 25。CPU3 必须立即响应，将数据包从 WiFi 芯片的内存通过 PCIe 总线搬运到主内存（DDR）中，并封装成 sk_buff 结构。
- ACK 响应控制 (SIFS 时间窗)：WiFi 协议要求在极短的时间内回复 Block Ack。如果 CPU3 忙于其他事务（如 RPS 洗包），响应变慢，对端就会认为丢包，从而触发 BA MISS。
- NAPI 轮询调度：CPU2 负责执行 mt76_poll。它就像一个高速旋转的转子，不停地检查硬件 Ring Buffer，确保缓冲区不溢出。
- 信标 (Beacon) 与同步：维持与中继上级的时钟同步。

*CPU2 (MT7915e-hif / mt76-tx)：无线发送的“排队调度员” (Tx Logic)*
- CPU2 运行的是驱动层的 发送工作队列。虽然发送动作最终由硬件完成，但“发什么、怎么发”全靠 CPU2：
- 聚合帧构造 (A-MPDU/A-MSDU)：这是最耗 CPU 的地方。你限制了 MSDU=3，CPU2 就要负责把内存里零散的小包，按照 M3 的规格“打包”成一个巨大的聚合帧。
- Tx 描述符管理：为每个要发送的包分配 DMA 描述符，告诉硬件这些包在内存的什么位置。
- 拥塞算法反馈 (Cubic/BBR)：你现在切到了 Cubic，CPU2 就要根据丢包和 RTT 情况，计算当前的 发送窗口 (CWND)。如果窗口缩了，CPU2 就得把包压在队列里不发。
- 重传逻辑处理：当 CPU3 收到对端的“丢包报告”后，会通知 CPU2，CPU2 负责从重传队列里找出那个包，重新塞进发送 Ring Buffer。
- CPU2 是你的“弹药调度中心”。如果 CPU2 慢了，WiFi 发送就会“卡顿”，表现为吞吐量曲线出现锯齿。

*CPU3 做什么*
- 物理投递： 为了平衡指令发射带宽，内核会**自动**将该 Timer 任务投递到与CPU2共享 L1 Cache 的最邻近空闲 VPE（即 CPU3）。这样既利用了 CPU3 的空闲发射槽位，又保证了 Timer 访问 skb 数据时依然能从共享的 L1 Cache 中直接命中，不需要走 OCP 总线。
- CPU 3 的 90% 高负载：主要是MT7621的GIC时钟高频调度切换产生的。 mt76-tx 是 “因”，CPU3 的 HRTIMER 爆发是 “果”。
 
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

CPU 2 MT7915 硬中断(rx, RPS=0)：在前线拼命收割（NAPI）。

u9:1+napi_workq：在后方打扫战场（洗包）。

CPU 2 (mt76-tx)：在隔壁全速发车（DMA 填包）。

migration/2：在门口站岗，确保没人敢乱闯 CPU 2 的领地。

Softnet >Squeeze 始终为０ (５亿包处理）

这套“影子政府”般的内核架构，是 MT7621 冲击 300M+ 稳态的终极秘密。

## Sysctl.conf 深度调优（针对BBR算法的内存管理和延迟计算方法）
- net.ipv4.tcp_notsent_lowat = 1048576

Buffer Bloat 缓冲区膨胀消除： lowat=1MB 限制了在套接字发送队列中堆积的数据量。这不仅减轻了 CPU2 (mt76-tx) 的封装压力，更重要的是让 CPU3 (Rx/IRQ) 腾出了处理 ACK 回包的调度间隙。

- net.ipv4.tcp_min_rtt_wlen=5

BBR 采样逻辑闭环： BBR 依赖 RTT 采样。以前没限 lowat 时，大量的 buffer 堆积伪造了“高延迟”，导致 BBR 误判带宽缩减。

```
# BBR Memory & Pacing Stabilization
# Use BBR for balanced CPU/throughput
net.ipv4.tcp_congestion_control = bbr
# CRITICAL: Limits local buffer bloat (1MB for BBR, 2MB is more better for CUBIC); prevents Order-0 memory depletion and CPU3 "drowning"
net.ipv4.tcp_notsent_lowat = 1048576
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

## /proc/pagetypeinfo 中的奥秘, BBR vs. CUBIC
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

### BBR 算法特性 与 Linux 内存紧缩 (Compaction) 之间的底层冲突
简单来说：Cubic 是“盲目灌包型”，而 BBR 是“高精度测量型”。在内存紧缩这种极其耗费 CPU 指令周期的动作面前，两者的反应截然不同。

**1. 为什么 Cubic 跑着没事？**

- Cubic 的逻辑极其简单：只要没丢包，我就按窗口曲线加压。
- 抗抖动性强：当执行 compact_memory 时，CPU 会瞬间被抢占去搬运物理页。Cubic 的发包节奏虽然会卡顿几毫秒，但它不依赖高精度的 RTT（往返时间）测量。
- 不敏感：搬运内存导致的系统微小延迟（Jitter），对 Cubic 来说只是“发包慢了一点点”，等内存搬完了，它继续按部就班发包，不会产生逻辑混乱。

**2. 为什么 BBR 切换回来就容易出问题？**

- BBR 的核心是基于 RTprop (最小往返时间) 和 BtlBw (瓶颈带宽) 的实时建模。
- RTT 采样污染：compact_memory 会导致内核进入 "Stop the World" 级别的瞬间卡顿。如果 BBR 在这一瞬间采样 RTT，会抓到一个巨大的延迟毛刺。
- BDP 计算崩溃：BBR 根据采样到的 RTT 计算 BDP (带宽延迟积)。由于内存搬运导致的瞬时延迟，BBR 可能误判链路发生了严重拥塞，从而大幅下调发送速率。
- CPU3 连锁反应：BBR 试图通过 Pacing（平滑发包）来控制速率。如果此时 CPU3 正忙于内存紧缩后的 NAPI 恢复，而 BBR 又因为采样错误发送了不规律的探测包，两者冲突极易导致 Soft Lockup (软锁死)。
- 上下文切换开销：从 Cubic 切换到 BBR 本身就需要重新初始化内核的拥塞控制状态机。在内存极度碎片化（正在紧缩）时切换，会导致内核在分配 BBR 所需的监控结构体时触发 Atomic Allocation Failure。
  
**3. 底层机制：BBR 是“手术刀”，Cubic 是“大锤”**

- Cubic：像大锤，系统抖一下，它只是停一下。
- BBR：像手术刀，必须在微秒级精度下操作。compact_memory 这种“搬家”动作会让手术台剧烈晃动，BBR 的算法模型会立即崩坏，表现出来就是流量断流甚至驱动层 Kernel Panic。

### sysctl.conf 调优后的内存分布 (压力测试 运行初期1~2小时）
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

### sysctl.conf 调优后的内存分布 （压力测试中期-9小时后）
```
Page block order: 10
Pages per block:  1024

Free pages count per migrate type at order       0      1      2      3      4      5      6      7      8      9     10
Node    0, zone   Normal, type    Unmovable    122    145     88     31      3      0      1      0      1      1      2
Node    0, zone   Normal, type      Movable      5     13     14     27     16      8      4      3      0      0      9
Node    0, zone   Normal, type  Reclaimable     17     39     35     11      0      0      0      0      0      1      0
Node    0, zone   Normal, type   HighAtomic      0      0      0      0      0      0      0      0      0      0      0

Number of blocks type     Unmovable      Movable  Reclaimable   HighAtomic
Node 0, zone   Normal           21           40            3            0
```
内核的Order 9,10仍有1，2盈余，很不错！

写了个脚本每隔两秒刷新下/proc/pagetypeinfo
发现内核Unmovable绝大数时间是order 0~5 在组合分散，6，7目前都为0，有时会向8借1个，8为0，但马上还给8，
movable好像基本不动，只有order 0, 1在增减。

**1. 揭秘“向 Order 8 借调”：内核的生存博弈**
在 MT7621 (MIPS) 上，Order 8 代表 1MB 的连续内存。
触发点： 当 MT7915 驱动 或 协议栈逻辑 需要处理一波密集的 MSDU 聚合 (M3) 或 BBR 的高频 ACK 响应时，低位的 Unmovable（Order 0-5）可能瞬间被描述符（Descriptors）填满。
借调行为： 内核被迫向上级（Order 8）拆借一块 1MB 的大内存，迅速粉碎成多个小块（Order 0-3）来承载这些瞬时爆发的中断请求。
迅速归还： 一旦这波包处理完（ACK 发出或 DMA 传输结束），这些临时的描述符被释放。由于你开启了 NAPI 调度平衡 和 lowat=1MB，系统没有后续的堆积压力，内存分配器（Buddy System）会立刻尝试合并这些碎片并还给 Order 8。

**2. 为什么 Movable（可移动）基本不动？**
这是本次压测最成功的调优结果：
BBR 的功劳： 因为 lowat=1MB 严格控制了应用层（iperf3）往内核塞数据的节奏，导致 Socket Buffer (sk_buff) 的申请量处于一种极其稳定的“等量代换”状态。
物理层保障： 既然数据包在内核中不堆积（发得快、收得快），Movable 内存（存放数据包载荷）就保持了极高的周转率，所以你看到高位（Order 10 = 9个）稳如泰山。

**3. “Unmovable 6, 7 为 0”的潜在风险？**
不是风险但胜似风险，Order 6,7,8 每一分钟或时间更长（表示更稳）会拆借交换一次，变成001, 101, 201 ...
处于0rder 0-5 的小块内存不断地频繁向下拆借， 极上动用以上拆借，只要 Unmovable 的 Order 9/10 不消失，哪怕 Order 6/7/8 全归零，系统也是安全的。

**更多内幕**
- 系统目前手里攥着大量的“零钱”。
Unmovable Order 1 和 2 的数量远高于 Order 0，这说明 NAPI 调度 和 M3 聚合驱动 正在疯狂周转。每当一个 Wi-Fi 帧处理完，描述符释放，立刻就被下一个包接手了。结论： 内存周转率极高，没有发生“内存空洞”导致的死锁。
- Order 8 归零的真相
状态： Order 8 为 0，但 Order 7 为 1，Order 6 为 2。
逻辑： 这是一个典型的“向下拆借”态。内核刚刚把一个 Order 8 拆开了，分成了 1个 Order 7 和 2个 Order 6。
猜想： 这大概率发生在你 iperf3 曲线从“深坑”爬升的阶段。内核通过牺牲大块内存的连续性，换取了足够多的描述符位，支撑起了那一波 310Mbps 的吞吐爆发。

### sysctl.conf 调优后的内存分布 （压力测试后期-15小时后）
```
Page block order: 10
Pages per block:  1024

Free pages count per migrate type at order       0      1      2      3      4      5      6      7      8      9     10
Node    0, zone   Normal, type    Unmovable     73    141    105     12      3      1      1      0      1      1      2
Node    0, zone   Normal, type      Movable    159    107     42      7      1      2      2      1      1      0      5
Node    0, zone   Normal, type  Reclaimable     23     39     35     11      0      0      0      0      0      1      0
Node    0, zone   Normal, type   HighAtomic      0      0      0      0      0      0      0      0      0      0      0

Number of blocks type     Unmovable      Movable  Reclaimable   HighAtomic
Node 0, zone   Normal           21           40            3            0
```
- 内存博弈：Movable 的“极限抗压”与 Reclaimable 的复苏
**Movable Order 10 剩余 5 个：** 昨晚掉到 6 个后，现在稳定在 5 个。这说明系统在 200M-240Mbps 的吞吐下，已经形成了一套“拆借与合并”的动态收支平衡。
**Reclaimable (可回收) 的出现：** 注意到 Reclaimable 出现了一个 Order 9 和一些低位碎片。这非常好！说明内核在压力下，成功将一部分原本被占用的内存标记为了可回收态，增加了系统的灵活性。
- Unmovable 依然坚固： Order 8, 9, 10 (1, 1, 2) 依然存在。这证实了你的 IRQ 隔离和 lowat 调优 确实保住了内核的底线。
- 吞吐量与重传率：1.0 的警戒线
重传率 1.02 (万分之)： 这是个关键信号。它微幅突破了 1.0 的心理阈值。
原因分析： 结合 MCS 9 (866.7M) 和 BA MISS (188/s)，可以看出系统目前处于“算力换吞吐”的边缘。MCS 9 调制极高，对 CPU3 的干扰（Interrupt Latency）变大，导致了微小的重传增加。
- 策略评价： 吞吐量维持在 244Mbps 且 CPU 占用率（86.5%）相比昨晚的 94% 有所回落，说明系统找到了一个更节能的平衡点。
- 电脑端的速率： 能稳定在250~300M区域 ， 但如果开了监控会干扰BBR RTT的延迟探测，速率会下降50M左右，但能在200M，关闭监控后，2分钟左右会回升到250M+

**开启监控时**
  
<img width="384" height="180" alt="image" src="https://github.com/user-attachments/assets/560bccfb-90d7-4bc8-852d-ecf43834194e" />

- SSH/监控的隐形成本：
  每一个 top、cat /proc/pagetypeinfo 或 slabinfo 的执行，都会触发一次 User Space（用户态）到 Kernel Space（内核态）的上下文切换。
- 内存锁竞争：
  读取 /proc 文件系统需要遍历内核的数据结构，这会触发行锁（Spinlock）。在高频中断（每秒 180+ BA MISS）和 BBR 高频采样下，这些微小的锁等待会导致 RTT 瞬时抖动。
- BBR 的反应：
  BBR 对 RTT 的增加极度敏感。它感测到了由于监控引起的微小延迟增加，判定为“瓶颈带宽缩小”，于是立即主动收缩发送窗口（Window Reduction），这就是你看到的 50M 跌幅。

**关闭监控后**

<img width="384" height="180" alt="image" src="https://github.com/user-attachments/assets/60dec8ad-7d22-41f2-bf50-4faf7e00344c" />

### sysctl.conf 调优后的内存分布 （压力测试后期-17小时后）
```
Page block order: 10
Pages per block:  1024

Free pages count per migrate type at order       0      1      2      3      4      5      6      7      8      9     10
Node    0, zone   Normal, type    Unmovable     60    146    106      5      0      2      3      1      2      0      2
Node    0, zone   Normal, type      Movable    207    170     53     16      2      3      1      1      2      1      4
Node    0, zone   Normal, type  Reclaimable      5     17     35     11      0      0      0      0      0      1      0
Node    0, zone   Normal, type   HighAtomic      0      0      0      0      0      0      0      0      0      0      0

Number of blocks type     Unmovable      Movable  Reclaimable   HighAtomic
Node 0, zone   Normal           21           40            3            0
```
不同大小内存页依然有拆借，但此时，内核系统已明显出现了内存延迟（长期运行后SLAB缓存着色延迟）问题诱发 napi-workq 进程在处理洗包时变慢，硬中断DMA延迟，当BBR RTT感知到，又下调发包速率。不要动任何参数，BBR会自愈修复, 修复后的速率能在250M+撑几分钟，但又会回落 ，然后再反复，这就是真实水平。

### sysctl.conf 调优后的内存分布 （压力测试后期-20小时后结束）

```
Page block order: 10
Pages per block:  1024

Free pages count per migrate type at order       0      1      2      3      4      5      6      7      8      9     10
Node    0, zone   Normal, type    Unmovable    233    207    112      7      8     17      4      1      1      0      2
Node    0, zone   Normal, type      Movable   1591   1102    617    281     90     48     18      4      1      3      4
Node    0, zone   Normal, type  Reclaimable    285    172     75     43     11      4      1      0      0      1      0
Node    0, zone   Normal, type   HighAtomic      0      0      0      0      0      0      0      0      0      0      0

Number of blocks type     Unmovable      Movable  Reclaimable   HighAtomic
Node 0, zone   Normal           21           40            3            0
```
核心参数对比表：稳态 vs 结束我们可以清晰地看到系统是如何在压力消失后“喘息”的：
指标 (Order) 压测中 (15H)压测后(20H+)
Unmovable O3 11 7 释放了 4 个，说明驱动部分聚合帧缓存已归还。
Unmovable O4-5 1/2 8/17 异常升高。说明小块碎片在压力释放后尝试向上合并，但卡在了中阶。
Movable O0 152 1591 业务逻辑内存完全释放，系统转入静默。
Order 10(Total) 6(2+4) 6(2+4)
- 内核是稳定的： 没有 Panic，说明 SLAB 至少在逻辑链条上是完整的。
- 效率是受损的： 这种“不完全合并”的状态，意味着系统的 算力天花板 已经因为内存延迟而永久下移了约 10%-15%。

## iperf3 电脑端结束最终状态
20小时结束后， iperf3的性能报告：
[ ID] Interval           Transfer     Bandwidth       Retr
[  5]   0.00-72000.00 sec  0.00 %v絪   248 Mbits/sec  166360             sender
[  5]   0.00-72000.00 sec  0.00 %v絪   248 Mbits/sec                  receiver

iperf Done.

最终Bandwidth定格在 248 Mbits/sec。相比初期的 300Mbps 均线，跌幅约 17.3%。系统没有崩溃，而是通过 BBR 的感知，用速率换取了生存空间

## 结论 
$${\color{red}
(TODO: 不准确，因为3小时前手工drop_caches可能导致VFS, 另外, 持续的MT7915e mac硬中断在CPU3上，导致HRTIMER停摆）
}$$
实验结论：SLAB 的“带病生存”模型
这次压测证明了一个关键结论：在嵌入式 Linux 网络调优中，内存分配的老化确实会导致“算力贬值”，但只要拥塞控制算法（BBR）足够灵敏，且人为压低了发送窗口（notsent_lowat），**系统可以进入一种“性能衰减但逻辑稳态”的长效运行模式**。

**20小时压测结束后，实际又做了两次相同iperf3参数，但只有60秒的测试，第一次无法达到200M+平均水平，第二次能到250M+平均值。**
