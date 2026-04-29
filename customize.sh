#!/system/bin/sh

if ! type ui_print >/dev/null 2>&1; then
  ui_print() { echo "$1"; }
fi

ui_print ""
ui_print "===== AutoFire 应用定时重启模块 ====="
ui_print ""
ui_print "支持微信和抖音的定时重启、Action 按钮触发和 KSU/APatch WebUI 配置。"
ui_print ""

if [ -n "$MODPATH" ] && type set_perm >/dev/null 2>&1; then
  set_perm "$MODPATH/service.sh" 0 0 0755
  set_perm "$MODPATH/action.sh" 0 0 0755
  set_perm_recursive "$MODPATH/script" 0 0 0755 0755
fi
