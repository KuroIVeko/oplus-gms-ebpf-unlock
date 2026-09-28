#!/system/bin/sh
# late_start service：清空 Oplus eBPF 联网限制名单，解除对 GMS 全家桶（及任何 App）的
# WLAN/蜂窝联网限制。
#
# 系统不只在开机时写入这张表：VPN（虚拟网卡）每次连接/断开都会触发重新写入。
# 所以这里常驻监听 TUN 网卡变化（ip monitor link，阻塞等待，不占 CPU），
# 有变化时延迟几秒再检查清除；另有低频兜底检查，防止其他未知的写入路径。
#
# 不按包名挑 UID，而是把名单里的条目全部删掉：这几张表的作用就是"禁止某 UID 联网"，
# 系统往里写哪些包也不固定（例如 GSF 时有时无），全清最省事也最稳。

MODDIR=${0%/*}
BPFTOOL="$MODDIR/bpftool"
LOG="$MODDIR/unblock_gms.log"
PENDING="$MODDIR/.pending"

# wlan = WLAN，qcom = 骁龙平台蜂窝，mtk = 天玑平台蜂窝；不存在的表会自动跳过。
# accept_* / allow_* 是放行名单，不能清，所以不在这里。
MAPS="map_oplus-netd_app_wlan_socket_uid_limit_map map_oplus-netd_app_qcom_socket_uid_limit_map map_oplus-netd_app_mtk_socket_uid_limit_map"

# 网卡变化后先等 3 秒让系统写完表再清除（实测写入在 2 秒内完成），再过 10 秒补查一次
EVENT_DELAYS="3 10"
# 兜底检查间隔（秒）
FALLBACK_INTERVAL=300
# 日志超过这个大小就只保留后半部分
LOG_MAX_BYTES=262144

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"
}

trim_log() {
  [ -f "$LOG" ] || return
  size=$(stat -c '%s' "$LOG" 2>/dev/null) || return
  if [ "$size" -gt "$LOG_MAX_BYTES" ]; then
    tail -c $((LOG_MAX_BYTES / 2)) "$LOG" > "$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"
  fi
}

if [ ! -x "$BPFTOOL" ]; then
  log "错误: 找不到可执行的 bpftool ($BPFTOOL)，模块无法工作"
  exit 1
fi

# 把每张表里的条目全部删掉；表为空时只有一次 dump 的开销
unblock_once() {
  reason="$1"
  for m in $MAPS; do
    mapfile="/sys/fs/bpf/$m"
    [ -e "$mapfile" ] || continue
    keys=$("$BPFTOOL" map dump pinned "$mapfile" 2>/dev/null | sed -n 's/^key: \(.*[0-9a-f]\) *value:.*/\1/p')
    [ -n "$keys" ] || continue
    n=0
    while read -r key; do
      "$BPFTOOL" map delete pinned "$mapfile" key hex $key >/dev/null 2>&1 && n=$((n+1))
    done <<EOF
$keys
EOF
    log "清空[$reason]: $m（$n 条）"
    trim_log
  done
}

# 等待 /sys/fs/bpf 上这张表出现，最多等 60 秒
i=0
while [ ! -e /sys/fs/bpf/map_oplus-netd_app_wlan_socket_uid_limit_map ] && [ $i -lt 60 ]; do
  sleep 1
  i=$((i+1))
done

rm -f "$PENDING"
log "===== 模块启动 ====="

# 开机后前 5 分钟每 5 秒检查一次（应对开机阶段系统服务的延迟写入）
i=0
while [ $i -lt 60 ]; do
  unblock_once "开机"
  sleep 5
  i=$((i+1))
done

log "开机检查结束，转入常驻监听（网卡变化触发 + 每 ${FALLBACK_INTERVAL} 秒兜底）"

# 兜底：低频定时检查，表为空时只有一次 dump 的开销
(
  while true; do
    sleep "$FALLBACK_INTERVAL"
    unblock_once "定时"
  done
) &

# 主逻辑：监听网卡增删/状态变化（VPN 连接/断开会创建/销毁 tun 网卡）。
# 只关心 TUN 类网卡（link/none）：蜂窝数据的 rmnet_* 是 link/[519]，
# 会阵发性地频繁变化，不过滤的话几乎等于高频轮询。
# 一次 VPN 开关会连续产生多条事件，用 PENDING 标记合并成一次延迟检查。
while true; do
  ip -o monitor link 2>/dev/null | while read -r line; do
    case "$line" in
      *link/none*) ;;
      *) continue ;;
    esac
    [ -e "$PENDING" ] && continue
    touch "$PENDING"
    (
      first=1
      for d in $EVENT_DELAYS; do
        sleep "$d"
        if [ $first -eq 1 ]; then
          rm -f "$PENDING"
          first=0
        fi
        unblock_once "网卡变化"
      done
    ) &
  done
  # ip monitor 意外退出时稍后重启监听
  log "ip monitor 退出，5 秒后重启监听"
  sleep 5
done
