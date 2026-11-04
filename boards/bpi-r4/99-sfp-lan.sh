#!/bin/sh

# 1. SFP+ WAN (eth1) zu den LAN-Ports hinzufügen (normale LAN-Ports bleiben unberührt!)
uci add_list network.lan.ports='eth1'
uci del_list network.wan.ports='eth1' 2>/dev/null

# 2. Priorität für den normalen Kabel-WAN-Port festlegen (Hauptleitung)
# Eine niedrige Metric (z. B. 10) bedeutet: Höchste Priorität
uci set network.wan.metric='10'

# 3. Vorbereitung für das 5G-Modem (Backup-Leitung)
# Sobald du das 5G-Interface "wwan" in LuCI anlegst, bekommt es diese höhere Metric.
# Eine höhere Metric (z. B. 40) bedeutet: Wird nur genutzt, wenn die Hauptleitung (10) down ist.
uci set network.wwan.metric='40' 2>/dev/null

# 4. Änderungen dauerhaft speichern
uci commit network

exit 0
