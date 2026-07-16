#!/bin/bash
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
/bin/bash "$SCRIPT_DIR/install-offline.sh"
status=$?
printf '\n'
if [ "$status" -eq 0 ]; then
  printf '安装完成。按任意键关闭此窗口。\n'
else
  printf '安装失败（退出码 %s）。请保留窗口内容和安装报告。按任意键关闭。\n' "$status"
fi
IFS= read -r -n 1 _
exit "$status"
