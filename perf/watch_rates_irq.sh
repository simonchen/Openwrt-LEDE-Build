#!/bin/sh

# 参数检查
[ -z "$1" ] && echo "用法: $0 <目标MAC>" && exit 1
TARGET_MAC=$(echo "$1" | tr '[:upper:]' '[:lower:]')

# --- 1. 自动探测路径 (仅启动执行一次) ---
PHY_ID=$(ls /sys/kernel/debug/ieee80211/ | grep phy | sort -V | tail -n 1)
INTERFACE=$(iw dev | grep -A 5 "phy#${PHY_ID#phy}" | grep Interface | awk '{print $2}' | head -n 1)
HWMON_5G="/sys/class/hwmon/hwmon${PHY_ID#phy}"
TX_STATS="/sys/kernel/debug/ieee80211/$PHY_ID/mt76/tx_stats"
XMIT_QUEUES="/sys/kernel/debug/ieee80211/$PHY_ID/mt76/xmit-queues"

# --- 2. 初始化历史快照 ---
OLD_IRQ="/tmp/irq_p"
OLD_CPU="/tmp/cpu_p"
OLD_SN="/tmp/sn_p"
grep ":" /proc/interrupts > "$OLD_IRQ"
grep 'cpu ' /proc/stat > "$OLD_CPU"
cat /proc/net/softnet_stat > "$OLD_SN"

START_TIME=$(date +%s)
PREV_TIME=$(cat /proc/uptime | awk '{print $1}')
STATION_INFO=$(iw dev "$INTERFACE" station get "$TARGET_MAC" 2>/dev/null)
OLD_TX=$(echo "$STATION_INFO" | grep "tx bytes" | awk '{print $3}')
OLD_RX=$(echo "$STATION_INFO" | grep "rx bytes" | awk '{print $3}')
FIRST_BA=$(cat "$TX_STATS" | grep "BA miss count" | awk -F': ' '{print $2}')
OLD_BA=$FIRST_BA

# 颜色定义
G="\033[1;32m"; Y="\033[1;33m"; R="\033[0m"; C="\033[1;36m"; W="\033[1;37m"; P="\033[1;35m"

# --- 退出清理机制 ---
# 脚本退出时：1. 恢复光标显示  2. 清除屏幕下方残余  3. 正常换行
restore_cursor() {
    clear
    printf "\033[?25h\033[K\n  监控已停止.\n"
    exit 0
}

# 捕获 Ctrl+C (SIGINT) 和 终止信号 (SIGTERM)
trap restore_cursor INT TERM

# 强制清屏并隐藏光标
printf "\033[2J\033[?25l"

while true; do
    CURR_TIME=$(cat /proc/uptime | awk '{print $1}')
    
    # --- A. 极速数据采集 (同步点) ---
    CURR_IRQ=$(cat /proc/interrupts)
    CURR_SN=$(cat /proc/net/softnet_stat)
    CURR_CPU=$(cat /proc/stat)
    CURR_LOAD=$(cat /proc/loadavg | awk '{print $1,$2,$3}')
    STATION_INFO=$(iw dev "$INTERFACE" station get "$TARGET_MAC" 2>/dev/null)
    
    if [ -z "$STATION_INFO" ]; then
        printf "\033[H\033[J\n  ${Y}等待目标 $TARGET_MAC 重连...${R}\n"
        sleep 1; continue
    fi

    # 提取物理层与内存数据
    TX_BYTES=$(echo "$STATION_INFO" | grep "tx bytes" | awk '{print $3}')
    RX_BYTES=$(echo "$STATION_INFO" | grep "rx bytes" | awk '{print $3}')
    TX_RX_INTERVAL=$(awk -v t1=$PREV_TIME -v t2=$CURR_TIME 'BEGIN { printf "%.4f", t2 - t1 }')

    TX_BITRATE=$(echo "$STATION_INFO" | grep "tx bitrate" | awk -F'tx bitrate:' '{print $2}' | xargs | cut -c1-45)
    SIGNAL=$(echo "$STATION_INFO" | grep "signal avg" | awk -F'signal avg:' '{print $2}' | xargs)
    #CUR_BA=$(cat "$TX_STATS" | grep "BA miss count" | awk -F': ' '{print $2}')
    # --- 保持原有 CUR_BA 逻辑，同时提取 Count 计算百分比 ---
    # 我们用 awk 一次性扫描 TX_STATS，取出 BA miss count 和所有 Count 的总和
    BA_METRICS=$(awk '
        /Count:/ { for(i=2;i<=NF;i++) sum+=$i } 
        /BA miss count:/ { miss=$NF; printf "%d %.2f", miss, (sum>0 ? (miss/sum)*100 : 0) }
    ' "$TX_STATS")
    
    # 依然给 CUR_BA 赋值，确保你后面的 $((CUR_BA - FIRST_BA)) 逻辑不变
    CUR_BA=$(echo "$BA_METRICS" | awk '{print $1}')
    CUR_PERCENT=$(echo "$BA_METRICS" | awk '{print $2}')
    HW_Q=$(cat "$XMIT_QUEUES" | grep "MAIN" | awk '{print $3}')
    TEMP=$(awk '{printf "%.1f", $1/1000}' "$HWMON_5G/temp1_input" 2>/dev/null || echo "N/A")
    CRIT=$(awk '{printf "%.1f", $1/1000}' "$HWMON_5G/temp1_crit" 2>/dev/null || echo "N/A")
    MEM=$(grep MemFree /proc/meminfo | awk '{printf "%.2f", $2/1024}')
    SLAB_INFO=$(grep -E "skbuff_head_cache|skbuff_fclone_cache|skbuff_ext_cache" /proc/slabinfo)

    # --- B. 计算增量与速率 ---
    ET=$(( $(date +%s) - START_TIME ))
    TIME_STR=$(printf "%02d:%02d:%02d" $((ET/3600)) $((ET%3600/60)) $((ET%60)))
    
    DL=$(awk -v c=$TX_BYTES -v o=$OLD_TX -v dt=$TX_RX_INTERVAL 'BEGIN { 
        diff = c - o; if (diff < 0) diff = (4294967296 - o) + c;
        if (dt <= 0.01) printf "0.00"; else printf "%.2f", (diff * 8 / 1048576) / dt 
    }')
    UL=$(awk -v c=$RX_BYTES -v o=$OLD_RX -v dt=$TX_RX_INTERVAL 'BEGIN { 
        diff = c - o; if (diff < 0) diff = (4294967296 - o) + c;
        if (dt <= 0.01) printf "0.00"; else printf "%.2f", (diff * 8 / 1048576) / dt 
    }')

    # --- C. 统一流式界面输出 (强制回到左上角) ---
    printf "\033[H"
    echo "======================================================================================================"
    echo -e "   ${G}MT7915 深度监控 v9.5 (流式对齐修正版)${R}" "   目标设备: ${C}${TARGET_MAC}${R}"
    echo "======================================================================================================"
    
    # 1. CPU & Load
    echo "$CURR_CPU" | awk -v old_file="$OLD_CPU" '
    BEGIN {
        while ((getline < old_file) > 0) {
            if($1 ~ /^cpu[0-9]/) { id=$1; u[id]=($2+$3+$4+$7+$8+$9); t[id]=(u[id]+$5+$6); }
        }
        close(old_file);
    }
    /^cpu[0-9]/ {
        id=$1; cur_u=($2+$3+$4+$7+$8+$9); cur_t=(cur_u+$5+$6);
        du=cur_u-u[id]; dt=cur_t-t[id]; us[id]=(dt>0)?(du/dt*100):0;
    }
    END {
        printf " CPU 占用: \033[1;35m%.1f%%  %.1f%%  %.1f%%  %.1f%%\033[0m\033[K\n", us["cpu0"], us["cpu1"], us["cpu2"], us["cpu3"]
    }'
    printf " 系统负载: ${Y}%-18s${R} | 运行时间: %s\033[K\n" "$CURR_LOAD" "$TIME_STR"
    echo -e "------------------------------------------------------------------------------------------------------\033[K"
    
    # 2. 物理状态区
    printf " 物理节点: %-15s 信号强度: %-15s\033[K\n" "$PHY_ID ($INTERFACE)" "$SIGNAL"
    printf " 5G 温度: %-6s (限值:%s℃) | 空闲内存: ${G}%-5s MB${R}\033[K\n" "${TEMP}℃" "$CRIT" "$MEM"
    echo -e "------------------------------------------------------------------------------------------------------\033[K"
    echo -e " [SLAB 关键内存池 (Active/Total)]\033[K"
    echo "$SLAB_INFO" | awk '{printf "  %-18s: %s/%s\033[K\n", $1, $2, $3}'
    echo -e "------------------------------------------------------------------------------------------------------\033[K"
    
    # 3. 吞吐量与物理层状态
    #echo -e " [每秒吞吐量 (Mbps)]\033[K"
    printf " [每秒吞吐量 (Mbps)]  下载(DL): ${C}%-5s${R} Mbps | 上传(UL): ${G}%-5s${R} Mbps\033[K\n" "$DL" "$UL"
    echo -e "------------------------------------------------------------------------------------------------------\033[K"
    echo -e " [物理层状态]\033[K"
    printf "  协商速率: %-42s\033[K\n" "$TX_BITRATE"
    printf "  队列深度: %-10s | BA MISS Δ: %-10s\033[K\n" "$HW_Q" "$((CUR_BA - OLD_BA))"
    #printf "  累计 BA MISS: %-6s | 采样周期: %ss\033[K\n" "$((CUR_BA - FIRST_BA))" "$TX_RX_INTERVAL"
    printf "  累计 BA MISS: %-10s (%s%%) | 采样周期: %ss\033[K\n" \
           "$((CUR_BA - FIRST_BA))" "$CUR_PERCENT" "$TX_RX_INTERVAL"

    # MSDU stats.
    echo -e "------------------------------------------------------------------------------------------------------\033[K"
    awk -v W="\033[K" '
# 1. 捕获 SU 总数 (第 6 列)
/Tx single-user successful MPDU counts:/ { su_total = $6 }

# 2. 捕获 MSDU 1-4 统计 (第 5 列索引, 第 9 列 Count)
/AMSDU pack count of [1-4] MSDU in TXD:/ {
    idx = $5
    count = $9
    msdu[idx] = count
    msdu_sum += count
}

END {
    if (su_total > 0) {
        # 第一行：显示标题和 SU Total
        printf "  [MSDU 聚合(SU 基准)] SU Total: %d"W"\n", su_total
        
        # 第二行：横向排列 1-4 项分布 (使用简减格式节省空间)
        printf "  "
        for (i=1; i<=4; i++) {
            p = (msdu[i] / su_total) * 100
            printf "M%d:%.1f%% ", i, p
        }
        
        # 紧接着显示 1-4 合计
        total_p = (msdu_sum / su_total) * 100
        printf "| 1-4合计: %d (%.2f%%)"W"\n", msdu_sum, total_p
    } else {
        printf "  Error: SU Total data not ready"W"\n"
    }
}' "$TX_STATS"
    echo -e "------------------------------------------------------------------------------------------------------\033[K"

    # --- RPS 状态生成 ---
    IFACES=$(echo $(iw dev | grep "Interface" | awk '{print $2}') "br-lan_dhcp" "br-lan" "lo")
    RPS_OUT="  RPS 状态: "
    for i in $IFACES; do
        RPS_P="/sys/class/net/$i/queues/rx-0/rps_cpus"
        [ -e "$RPS_P" ] && val=$(cat "$RPS_P") || val="-"
        RPS_OUT="${RPS_OUT}${i}:[${G}${val}${R}] "
    done
    echo -e "${RPS_OUT}\033[K"

    # --- 新增：ksoftirqd 列表 ---
    echo -e "------------------------------------------------------------------------------------------------------\033[K"
    printf " [ksoftirqd 占用]: "
    top -bn1 | grep "ksoftirqd/" | grep -v grep | awk -v R="$R" -v Red="\033[1;31m" -v G="\033[1;32m" '
    {
        u=0; for(i=NF; i>0; i--) if($i ~ /%/) { t=$i; sub(/%/,"",t); u=t+0; break; }
        col = (u > 15) ? Red : G;
        split($NF, a, "/"); cpu_id=substr(a[2], 1, 1);
        printf "CPU%s:%s%4.1f%%%s  ", cpu_id, col, u, R;
    } END { printf "\033[K\n"; }'

    # --- kworker (>0) ---
    printf " [kworker 占用]: "
    top -bn1 | grep "kworker/" | grep -v "grep" | awk -v R="\033[0m" -v Red="\033[1;31m" -v G="\033[1;32m" '
    {
        u=0; for(i=1;i<=NF;i++) if($i~/%/){t=$i; sub(/%/,"",t); u=t+0; break}
        if(u>0){
            col=(u>15.0)?Red:G; n=$NF; sub(/kworker\//,"",n);
            printf "%s:%s%.1f%%%s  ",n,col,u,R; f=1
        }
    } END { if(!f) printf "None"; printf "\033[K\n" }'
    
    # Softnet 表 (改用极速 awk 解析)
    echo -e "------------------------------------------------------------------------------------------------------\033[K"
    printf "${P}%-5s | %-20s | %-20s | %-20s | %-20s${R}\033[K\n" "CPU" "Packets (Δ)" "Dropped (Δ)" "Squeeze (Δ)" "IRQs (Δ)"
    echo "$CURR_SN" | awk -v old_sn="$OLD_SN" -v IV="$TX_RX_INTERVAL" -v G="$G" -v Red="$Red" -v W="\033[1;37m" '
    function h2d(h,   i, v, d, c) {
        d=0; h=toupper(h);
        for(i=1; i<=length(h); i++) {
            c=substr(h, i, 1);
            v=index("0123456789ABCDEF", c) - 1;
            d = d * 16 + v;
        }
        return d;
    }
    BEGIN {
        idx=0; while((getline < old_sn) > 0) {
            o_p[idx]=h2d($1); o_s[idx]=h2d($3); idx++;
        }
        close(old_sn);
    }
    {
        p=h2d($1); d=h2d($2); s=h2d($3); i=h2d($10);
        dp=int((p-o_p[NR-1]) / IV); ds=int((s-o_s[NR-1]) / IV);
        scol=(ds>0?Red:W);
        printf "CPU%-2d | %-10d ("G"+%-5d"W") | %-10d (+0    ) | %-10d ("scol"+%-5d"W") | %-10d (+0    )\033[K\n", NR-1, p, (dp<0?0:dp), d, s, (ds<0?0:ds), i;
    }'

    # 4. IRQ 表 (恢复固定列对齐)
    echo -e "------------------------------------------------------------------------------------------------------\033[K"
    printf "${W}%-5s | %-17s | %-17s | %-17s | %-17s | %-15s${R}\033[K\n" "IRQ" "CPU0(Δ Tot)" "CPU1(Δ Tot)" "CPU2(Δ Tot)" "CPU3(Δ Tot)" "NAME"
    echo -e "------------------------------------------------------------------------------------------------------\033[K"

    echo "$CURR_IRQ" | awk -v old_f="$OLD_IRQ" -v IV="$TX_RX_INTERVAL" -v G="$G" -v Y="$Y" -v R="$R" '
    BEGIN {
        while ((getline < old_f) > 0) {
            irq=$1; sub(/:/, "", irq); ov[irq,0]=$2; ov[irq,1]=$3; ov[irq,2]=$4; ov[irq,3]=$5;
        }
        close(old_f);
    }
    {
        irq=$1; sub(/:/, "", irq);
        d[0]=$2-ov[irq,0]; d[1]=$3-ov[irq,1]; d[2]=$4-ov[irq,2]; d[3]=$5-ov[irq,3];
        name=""; for(i=6;i<=NF;i++) name=name $i " ";
        
        if (d[0]>0 || d[1]>0 || d[2]>0 || d[3]>0 || name ~ /mt7915|resched/) {
            printf "%-5s | ", irq;
            for (i=0; i<4; i++) {
                col=(d[i]>500)?Y:G;
		_vd=int(d[i] / IV);
                vd=(_vd==0)?"":_vd;
                vt=($(i+2)==0)?"":$(i+2);
                printf "%s%-6s%s %-9s | ", col, vd, R, vt;
            }
            printf "%-15s\033[K\n", name;
        }
    }
    END { printf "\033[J"; }'

    # --- D. 状态更新 ---
    echo "$CURR_CPU" > "$OLD_CPU"
    echo "$CURR_IRQ" > "$OLD_IRQ"
    echo "$CURR_SN" > "$OLD_SN"
    OLD_TX=$TX_BYTES; OLD_RX=$RX_BYTES; OLD_BA=$CUR_BA
    PREV_TIME=$CURR_TIME
    
    sleep 3
done
