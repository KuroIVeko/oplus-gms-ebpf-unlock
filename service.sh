#!/system/bin/sh
# late_start service：开机后清除 Oplus eBPF 名单里对 GMS 全家桶的 WLAN/蜂窝联网限制。
# 实测系统只在开机时写入这张表一次，删除后运行期间不会被重新写回，
# 所以只在开机后的时间窗口内高频检查，之后退出，不常驻轮询。
#
# UID 通过包名动态解析，而不是硬编码：同一个包名在不同设备、不同安装顺序下
# 分配到的 UID 可能不一样，写死 UID 只对当初排查用的那台手机有效。

MODDIR=${0%/*}
BPFTOOL="$MODDIR/bpftool"
LOG="$MODDIR/unblock_gms.log"

MAPS="map_oplus-netd_app_wlan_socket_uid_limit_map map_oplus-netd_app_qcom_socket_uid_limit_map"
PACKAGES="com.google.android.gms com.android.vending com.google.android.gsf com.google.android.configupdater"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"
}

if [ ! -x "$BPFTOOL" ]; then
  log "错误: 找不到可执行的 bpftool ($BPFTOOL)，模块无法工作"
  exit 1
fi

# 包名 -> UID：取 /data/data/<pkg> 目录属主 UID。
# 比解析 pm/dumpsys 的文本输出更稳，不受 Android 版本输出格式差异影响。
resolve_uid() {
  dir="/data/data/$1"
  [ -d "$dir" ] || return 1
  stat -c '%u' "$dir" 2>/dev/null
}

uid_to_key() {
  uid="$1"
  printf '0x%02x 0x%02x 0x%02x 0x%02x' \
    "$((uid & 255))" "$((uid >> 8 & 255))" "$((uid >> 16 & 255))" "$((uid >> 24 & 255))"
}

unblock_once() {
  for pkg in $PACKAGES; do
    uid=$(resolve_uid "$pkg")
    if [ -z "$uid" ]; then
      log "跳过 $pkg：未安装，或 /data/data/$pkg 不存在"
      continue
    fi
    key=$(uid_to_key "$uid")
    for m in $MAPS; do
      mapfile="/sys/fs/bpf/$m"
      [ -e "$mapfile" ] || continue
      out=$("$BPFTOOL" map delete pinned "$mapfile" key $key 2>&1)
      rc=$?
      if [ $rc -eq 0 ]; then
        log "删除成功: $m key=$key ($pkg, uid=$uid)"
      fi
    done
  done
}

# 等待 /sys/fs/bpf 上这张表出现，最多等 60 秒
i=0
while [ ! -e /sys/fs/bpf/map_oplus-netd_app_wlan_socket_uid_limit_map ] && [ $i -lt 60 ]; do
  sleep 1
  i=$((i+1))
done

log "===== 模块启动，开机后高频检查 5 分钟 ====="

# 开机后前 5 分钟每 5 秒检查一次（应对系统服务延迟写入，且重新解析 UID 以防应用刚装好）
i=0
while [ $i -lt 60 ]; do
  unblock_once
  sleep 5
  i=$((i+1))
done

log "===== 高频检查结束，退出（实测运行期间不会被重新写回）====="
