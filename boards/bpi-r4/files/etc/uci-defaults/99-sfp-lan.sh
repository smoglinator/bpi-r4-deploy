#!/bin/sh

# 1. SFP+ WAN (eth1) zu den LAN-Ports hinzufügen (normale LAN-Ports bleiben unberührt!)
uci add_list network.lan.ports='eth1'
uci del_list network.wan.ports='eth1' 2>/dev/null

# 2. Priorität für den normalen Kabel-WAN-Port festlegen (Hauptleitung)
uci set network.wan.metric='10'

# 3. Vorbereitung für das 5G-Modem (Backup-Leitung mit höherer Metric)
uci set network.wwan.metric='40' 2>/dev/null

# 4. Änderungen dauerhaft speichern
uci commit network

exit 0
