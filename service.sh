#!/system/bin/sh
# late_start service：清除 Oplus eBPF 名单里对 GMS 全家桶的 WLAN/蜂窝联网限制。
#
# 系统不只在开机时写入这张表：VPN（虚拟网卡）每次连接/断开都会触发重新写入。
# 所以这里常驻监听网卡变化（ip monitor link，阻塞等待，不占 CPU），
# 有变化时延迟几秒再检查清除；另有低频兜底检查，防止其他未知的写入路径。
#
# UID 通过包名动态解析，而不是硬编码：同一个包名在不同设备、不同安装顺序下
# 分配到的 UID 可能不一样，写死 UID 只对当初排查用的那台手机有效。

MODDIR=${0%/*}
BPFTOOL="$MODDIR/bpftool"
LOG="$MODDIR/unblock_gms.log"
PENDING="$MODDIR/.pending"

MAPS="map_oplus-netd_app_wlan_socket_uid_limit_map map_oplus-netd_app_qcom_socket_uid_limit_map"
PACKAGES="com.google.android.gms com.android.vending com.google.android.gsf com.google.android.configupdater"

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

# 包名 -> UID：取应用数据目录属主 UID。
# 优先用 /data/user_de（设备加密存储，开机后解锁屏幕前就可读），
# /data/data 属于凭据加密存储，解锁前读不到，只作后备。
resolve_uid() {
  for dir in "/data/user_de/0/$1" "/data/data/$1"; do
    if [ -d "$dir" ]; then
      stat -c '%u' "$dir" 2>/dev/null && return 0
    fi
  done
  return 1
}

uid_to_key() {
  uid="$1"
  printf '0x%02x 0x%02x 0x%02x 0x%02x' \
    "$((uid & 255))" "$((uid >> 8 & 255))" "$((uid >> 16 & 255))" "$((uid >> 24 & 255))"
}

# 两张表都为空时直接返回，避免每次都解析 UID、刷日志
maps_empty() {
  for m in $MAPS; do
    mapfile="/sys/fs/bpf/$m"
    [ -e "$mapfile" ] || continue
    "$BPFTOOL" map dump pinned "$mapfile" 2>/dev/null | grep -q '^key:' && return 1
  done
  return 0
}

unblock_once() {
  reason="$1"
  maps_empty && return
  for pkg in $PACKAGES; do
    uid=$(resolve_uid "$pkg")
    if [ -z "$uid" ]; then
      log "跳过 $pkg：未安装"
      continue
    fi
    key=$(uid_to_key "$uid")
    for m in $MAPS; do
      mapfile="/sys/fs/bpf/$m"
      [ -e "$mapfile" ] || continue
      if "$BPFTOOL" map delete pinned "$mapfile" key $key >/dev/null 2>&1; then
        log "删除成功[$reason]: $m key=$key ($pkg, uid=$uid)"
      fi
    done
  done
  trim_log
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
# 一次 VPN 开关会连续产生多条事件，用 PENDING 标记合并成一次延迟检查。
while true; do
  ip monitor link 2>/dev/null | while read -r _; do
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
