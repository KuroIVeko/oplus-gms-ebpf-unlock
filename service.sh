#!/system/bin/sh
# late_start service：开机后持续清除 Oplus eBPF 名单里对 GMS 全家桶的 WLAN/蜂窝联网限制。
# 之所以是"持续监控"而不是一次性删除：系统服务可能在开机后延迟写入，
# 也可能在运行期间被重新写回，一次性删除无法保证长期生效。

MODDIR=${0%/*}
BPFTOOL="$MODDIR/bpftool"
LOG="$MODDIR/unblock_gms.log"

MAPS="map_oplus-netd_app_wlan_socket_uid_limit_map map_oplus-netd_app_qcom_socket_uid_limit_map"

# key 小端 4 字节 UID:
#   10263(Play商店) 10449(GMS) 10265(ConfigUpdater) 10259(GSF)
KEYS="0x17,0x28,0x00,0x00 0xd1,0x28,0x00,0x00 0x19,0x28,0x00,0x00 0x13,0x28,0x00,0x00"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"
}

if [ ! -x "$BPFTOOL" ]; then
  log "错误: 找不到可执行的 bpftool ($BPFTOOL)，模块无法工作"
  exit 1
fi

unblock_once() {
  changed=0
  for m in $MAPS; do
    mapfile="/sys/fs/bpf/$m"
    [ -e "$mapfile" ] || continue
    for k in $KEYS; do
      key=$(echo "$k" | tr ',' ' ')
      out=$("$BPFTOOL" map delete pinned "$mapfile" key $key 2>&1)
      rc=$?
      if [ $rc -eq 0 ]; then
        changed=1
        log "删除成功: $m key $k"
      fi
    done
  done
  return $changed
}

# 等待 /sys/fs/bpf 上这张表出现，最多等 60 秒
i=0
while [ ! -e /sys/fs/bpf/map_oplus-netd_app_wlan_socket_uid_limit_map ] && [ $i -lt 60 ]; do
  sleep 1
  i=$((i+1))
done

log "===== 模块启动，开始持续监控 ====="

# 开机后前 5 分钟每 5 秒检查一次（应对系统服务延迟/多次写入）
i=0
while [ $i -lt 60 ]; do
  unblock_once
  sleep 5
  i=$((i+1))
done

log "===== 前 5 分钟高频检查结束，转入低频常驻监控（每 60 秒）====="

# 之后每 60 秒检查一次，常驻后台防止运行期间被重新写回
while true; do
  unblock_once
  sleep 60
done
