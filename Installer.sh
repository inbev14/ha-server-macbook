#!/bin/bash
set -euo pipefail

HELPER="/Library/PrivilegedHelperTools/com.local.ha-server-control"
BCLM="/Library/PrivilegedHelperTools/com.local.ha-server-bclm"
SUDOERS="/etc/sudoers.d/ha-server-control"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUPPORT_DIR="$PROJECT_DIR"
WEBHOOK_IDS="$PROJECT_DIR/webhook-ids.conf"
PACKAGE_DIR="$PROJECT_DIR"
PACKAGE_FILE="$PROJECT_DIR/ha_server_macbook_package.yaml"
USER_NAME="$(id -un)"

printf '\n=== HA Server: Встановлення системних служб ===\n'
[ "$(uname -m)" = "x86_64" ] || { echo 'ПОМИЛКА: Підтримуються лише Mac на процесорах Intel.'; exit 1; }

# Читання конфігурації
CONFIG_FILE="$(dirname "$0")/config.conf"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ПОМИЛКА: Файл config.conf не знайдено! Скопіюйте config.example.conf у config.conf та заповніть його."
    exit 1
fi
source "$CONFIG_FILE"
echo "Конфігурацію завантажено. Служба сповіщень: $NOTIFY_SERVICE"

# Прописуємо дані в налаштування програми (UserDefaults)
defaults write com.local.ha-server-menu localHAURL -string "$HA_LOCAL_URL"
defaults write com.local.ha-server-menu remoteHAURL -string "$HA_REMOTE_URL"
defaults write com.local.ha-server-menu utmVMUUID -string "$UTM_VM_UUID"
defaults write com.local.ha-server-menu notifyService -string "$NOTIFY_SERVICE"
defaults write com.local.ha-server-menu heartbeatInterval -string "$HEARTBEAT_INTERVAL"

# Завантаження bclm (ліміт 80%)
echo "Завантаження утиліти bclm..."
sudo install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
TMP_DIR="$(mktemp -d)"
curl -sSL -o "$TMP_DIR/bclm.zip" 'https://github.com/zackelia/bclm/releases/latest/download/bclm.zip'
unzip -q -o "$TMP_DIR/bclm.zip" -d "$TMP_DIR"
sudo install -o root -g wheel -m 755 "$TMP_DIR/bclm" "$BCLM"
rm -rf "$TMP_DIR"

# Хелпер живлення
echo "Встановлення хелпера керування живленням..."
cat > /tmp/ha-server-control <<'HELPER_SCRIPT'
#!/bin/bash
set -u
MODE_FILE="/var/db/ha-server-mode"
LOW_BATT_FILE="/var/run/ha-server-lowbatt"
BCLM="/Library/PrivilegedHelperTools/com.local.ha-server-bclm"
PROTECT_FILE="/var/db/ha-server-battery-protection"

apply_server_power_settings() {
  /usr/bin/pmset -a disablesleep 1 sleep 0 disksleep 0
  /usr/bin/pmset -c autorestart 1 acwake 1 womp 1 2>/dev/null || true
  /usr/bin/pmset -b acwake 1 2>/dev/null || true
}

case "${1:-}" in
  start)
    mkdir -p /var/db /var/run; rm -f "$LOW_BATT_FILE"
    date > "$MODE_FILE"; chmod 644 "$MODE_FILE"
    apply_server_power_settings
    [ -f "$PROTECT_FILE" ] && [ -x "$BCLM" ] && "$BCLM" write 77 >/dev/null 2>&1 || true
    echo 'OK' ;;
  stop)
    rm -f "$MODE_FILE" "$LOW_BATT_FILE"
    /usr/bin/pmset -a disablesleep 0 sleep 10 disksleep 10 2>/dev/null || true
    echo 'OK' ;;
  status)
    if [ -f "$MODE_FILE" ]; then [ -f "$LOW_BATT_FILE" ] && echo 'PAUSED' || echo 'ON'; else echo 'OFF'; fi ;;
  protection-on)
    date > "$PROTECT_FILE"; chmod 644 "$PROTECT_FILE"
    [ -x "$BCLM" ] && "$BCLM" write 77 >/dev/null 2>&1 || true
    echo 'OK' ;;
  protection-status)
    if [ -f "$PROTECT_FILE" ]; then echo 'YES'; else echo 'NO'; fi ;;
  protection-off)
    rm -f "$PROTECT_FILE"
    [ -x "$BCLM" ] && "$BCLM" write 100 >/dev/null 2>&1 || true
    echo 'OK' ;;
  *) echo 'Usage: start|stop|status|protection-on|protection-off|protection-status'; exit 1 ;;
esac
HELPER_SCRIPT
sudo install -o root -g wheel -m 755 /tmp/ha-server-control "$HELPER"
rm -f /tmp/ha-server-control

cat > /tmp/ha-server-sudoers <<SUDOERS_FILE
$USER_NAME ALL=(root) NOPASSWD: $HELPER start
$USER_NAME ALL=(root) NOPASSWD: $HELPER stop
$USER_NAME ALL=(root) NOPASSWD: $HELPER protection-on
$USER_NAME ALL=(root) NOPASSWD: $HELPER protection-off
SUDOERS_FILE
sudo install -o root -g wheel -m 440 /tmp/ha-server-sudoers "$SUDOERS"
rm -f /tmp/ha-server-sudoers

# Генерація YAML пакету для HA
mkdir -p "$SUPPORT_DIR" "$PACKAGE_DIR"
chmod 700 "$SUPPORT_DIR"
if [ -s "$WEBHOOK_IDS" ] && grep -Eq '^LOCAL_ID=[a-f0-9]{64}$' "$WEBHOOK_IDS"; then
  LOCAL_ID="$(awk -F= '$1=="LOCAL_ID"{print $2}' "$WEBHOOK_IDS")"
  REMOTE_ID="$(awk -F= '$1=="REMOTE_ID"{print $2}' "$WEBHOOK_IDS")"
else
  LOCAL_ID="$(openssl rand -hex 32)"; REMOTE_ID="$(openssl rand -hex 32)"
  { printf 'LOCAL_ID=%s\nREMOTE_ID=%s\n' "$LOCAL_ID" "$REMOTE_ID"; } > "$WEBHOOK_IDS"
  chmod 600 "$WEBHOOK_IDS"
fi

cat > "$PACKAGE_FILE" <<YAML
input_datetime:
  ha_server_macbook_last_seen:
    name: MacBook Server Last Seen
    has_date: true
    has_time: true
input_text:
  ha_server_macbook_status:
    name: MacBook Server Status
    max: 255
  ha_server_macbook_last_warning_id:
    name: MacBook Server Last Warning ID
    max: 80
template:
  - sensor:
      - name: MacBook Server Heartbeat Age
        unique_id: ha_server_macbook_heartbeat_age
        icon: mdi:heart-pulse
        device_class: duration
        unit_of_measurement: min
        state_class: measurement
        availability: "{{ states('input_datetime.ha_server_macbook_last_seen') not in ['unknown', 'unavailable', 'none', ''] }}"
        state: >-
          {{ ((as_timestamp(now()) - as_timestamp(states('input_datetime.ha_server_macbook_last_seen'))) / 60) | round(0) | int }}
automation:
  - id: ha_server_macbook_webhook_heartbeat
    alias: HA Server — MacBook heartbeat
    mode: queued
    max: 10
    triggers:
      - trigger: webhook
        webhook_id: "$LOCAL_ID"
        allowed_methods: [POST]
        local_only: true
      - trigger: webhook
        webhook_id: "$REMOTE_ID"
        allowed_methods: [POST]
        local_only: false
    variables:
      mac_status: "{{ trigger.json.status | default('unknown') }}"
      mac_event: "{{ trigger.json.event | default('heartbeat') }}"
      mac_battery: "{{ trigger.json.battery_percent | default(-1) | int }}"
      mac_power: "{{ trigger.json.power_source | default('unknown') }}"
      mac_external: "{{ trigger.json.external_display | default(false) }}"
      mac_event_id: "{{ trigger.json.event_id | default('') }}"
    actions:
      - action: input_datetime.set_datetime
        target:
          entity_id: input_datetime.ha_server_macbook_last_seen
        data:
          datetime: "{{ now().strftime('%Y-%m-%d %H:%M:%S') }}"
      - action: input_text.set_value
        target:
          entity_id: input_text.ha_server_macbook_status
        data:
          value: "{{ mac_status }}|{{ mac_power }}|{{ mac_battery }}|external={{ mac_external }}"
      - choose:
          - conditions:
              - condition: template
                value_template: "{{ mac_event == 'battery_warning' and mac_event_id != states('input_text.ha_server_macbook_last_warning_id') }}"
            sequence:
              - action: input_text.set_value
                target:
                  entity_id: input_text.ha_server_macbook_last_warning_id
                data:
                  value: "{{ mac_event_id }}"
              - action: persistent_notification.create
                data:
                  notification_id: ha_server_macbook_battery_warning
                  title: "MacBook HA Server — батарея"
                  message: "MacBook працює від батареї. Останній заряд: {{ mac_battery }}%."
              - action: $NOTIFY_SERVICE
                data:
                  title: "MacBook HA Server — батарея"
                  message: "MacBook працює від батареї понад 10 хвилин. Заряд: {{ mac_battery }}%."
  - id: ha_server_macbook_heartbeat_stale
    alias: HA Server — втрачено heartbeat MacBook
    mode: single
    triggers:
      - trigger: numeric_state
        entity_id: sensor.macbook_server_heartbeat_age
        above: 5
        for: "00:02:00"
    conditions:
      - condition: template
        value_template: >-
          {% set p = states('input_text.ha_server_macbook_status').split('|') %}
          {{ p | length < 3 or p[1] != 'battery' or (p[2] | int(0)) > 20 }}
    actions:
      - action: persistent_notification.create
        data:
          notification_id: ha_server_macbook_heartbeat_stale
          title: "MacBook HA Server — немає зв'язку"
          message: "Немає зв'язку з Mac."
      - action: $NOTIFY_SERVICE
        data:
          title: "MacBook HA Server — немає зв'язку"
          message: "Home Assistant не отримував статус від MacBook понад 7 хвилин."
YAML
chmod 600 "$PACKAGE_FILE"

echo "✅ Системні служби встановлено! Конфігурацію HA згенеровано."
echo "Запустіть Build.command для збірки та старту програми."
