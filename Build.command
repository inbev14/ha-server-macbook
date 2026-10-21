#!/bin/bash
set -euo pipefail

echo "⚙️ Збираємо HA Server..."
APP_DIR="$HOME/Applications/HA Server.app"
APP_BINARY="$APP_DIR/Contents/MacOS/HA-Server"

# Зупиняємо поточну версію
/bin/launchctl bootout "gui/$(id -u)/com.local.ha-server-menu" 2>/dev/null || true
killall "HA-Server" 2>/dev/null || true

# Очищуємо та створюємо структуру
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

echo "🔨 Компілюємо App.swift..."
xcrun swiftc App.swift -o "$APP_BINARY"

# Створюємо Info.plist
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>HA Server</string>
  <key>CFBundleIdentifier</key><string>com.local.ha-server-menu</string>
  <key>CFBundleExecutable</key><string>HA-Server</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

chmod +x "$APP_BINARY"

echo "🚀 Запускаємо оновлену програму..."
open "$APP_DIR"
echo "✅ Успішно! Можеш перевіряти меню."
