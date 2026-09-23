#!/bin/sh
# Remove a source install (keeps the database in /var/lib/powermon).
set -eu
sudo systemctl disable --now powermon.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/powermon.service /usr/local/bin/powermon /etc/sysusers.d/powermon.conf
sudo systemctl daemon-reload
echo "removed; database kept in /var/lib/powermon"
