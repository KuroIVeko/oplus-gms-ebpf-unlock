#!/system/bin/sh
# 安装期脚本：定位/拷贝 bpftool 到模块目录，赋予可执行权限

ui_print "- Unblock GMS eBPF Limit 安装脚本"

if [ "$ARCH" != "arm64" ]; then
  ui_print "! 警告: 当前架构为 $ARCH，本模块只在 arm64 (OnePlus/ColorOS) 设备上验证过"
fi

if [ -x "$MODPATH/bpftool" ]; then
  ui_print "- 检测到模块包内自带 bpftool"
elif [ -x "/data/local/tmp/bpftool" ]; then
  ui_print "- 从 /data/local/tmp/bpftool 拷贝二进制到模块目录"
  cp -f "/data/local/tmp/bpftool" "$MODPATH/bpftool"
else
  ui_print "! 错误: 找不到 bpftool 可执行文件"
  ui_print "! 请先用 adb push 一份静态编译的 arm64 bpftool 到手机的 /data/local/tmp/bpftool"
  ui_print "! 下载地址: https://github.com/libbpf/bpftool/releases"
  ui_print "! (选择 bpftool-vX.X.X-arm64.tar.gz，解压后得到的 bpftool 即可)"
  ui_print "! 推送完成后重新安装本模块"
  abort "缺少 bpftool，安装终止"
fi

chmod 755 "$MODPATH/bpftool"
chmod 755 "$MODPATH/service.sh"

ui_print "- 安装完成。重启手机后模块会在后台持续清除 GMS/Play商店/GSF/ConfigUpdater 的 eBPF 联网限制"
ui_print "- 日志路径: /data/adb/modules/unblock_gms_ebpf/unblock_gms.log"
