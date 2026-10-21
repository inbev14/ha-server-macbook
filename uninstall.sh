#!/bin/bash
set -euo pipefail

printf '⚠️ Це видалить HA Server v5 та скине налаштування живлення.\n'
read -r -p 'Продовжити? Введи YES: ' answer
[ "$answer" = "YES" ] || { echo 'Скасовано.'; exit 0; }

HELPER="/Library/PrivilegedHelperTools/com.local.ha-server-control"
[ -x "$HELPER" ] && sudo "$HELPER" stop >/dev/null 2>&1 || true

launchctl bootout "gui/$(id -u)/com.local.ha-server-menu" 2>/dev/null || true
sudo launchctl bootout system/com.local.ha-server-guard 2>/dev/null || true

sudo rm -f "/Library/LaunchDaemons/com.local.ha-server-guard.plist"
sudo rm -f "/etc/sudoers.d/ha-server-control"
sudo rm -f "$HELPER" "/Library/PrivilegedHelperTools/com.local.ha-server-bclm"
rm -f "$HOME/Library/LaunchAgents/com.local.ha-server-menu.plist"
rm -rf "$HOME/Applications/HA Server.app"
sudo rm -f /var/db/ha-server-mode /var/db/ha-server-battery-protection 2>/dev/null || true

defaults delete com.local.ha-server-menu 2>/dev/null || true

printf '\n✅ HA Server v5 повністю видалено.\n'
