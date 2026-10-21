#!/bin/bash
set -u

UTMCTL="/Applications/UTM.app/Contents/MacOS/utmctl"
VM_UUID="98F4A813-2088-46B9-BD08-B26CC6D54239"
HELPER="/Library/PrivilegedHelperTools/com.local.ha-server-control"
BCLM="/Library/PrivilegedHelperTools/com.local.ha-server-bclm"

section() { printf '\n\033[1m%s\033[0m\n' "$*"; }

section 'Система та живлення'
sw_vers | grep ProductVersion
pmset -g batt
pmset -g | grep -E 'SleepDisabled|hibernatemode|acwake|womp' || true

section 'Статус UTM'
if [ -x "$UTMCTL" ]; then
  "$UTMCTL" status "$VM_UUID" 2>&1 || true
else
  echo 'UTM не знайдено.'
fi

section 'Права доступу та HA Server'
if [ -x "$HELPER" ]; then
  printf 'Режим сервера: '; "$HELPER" status || true
  ls -l "$HELPER"
else
  echo 'Хелпер не встановлено. Запустіть Installer.sh.'
fi

if [ -x "$BCLM" ]; then
  printf 'Ліміт bclm: '; "$BCLM" read || true
else
  echo 'bclm недоступний.'
fi

section 'Налаштування програми (UserDefaults)'
defaults read com.local.ha-server-menu 2>/dev/null || echo 'Налаштування ще не створені.'
