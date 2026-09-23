#!/bin/sh
# Install from source into /usr/local (use the .deb instead on Debian/Ubuntu). Run from the repo root.
set -eu
zig build -Drelease
sudo install -m 755 zig-out/bin/powermon /usr/local/bin/powermon
sudo install -m 644 contrib/powermon.sysusers /etc/sysusers.d/powermon.conf
sudo systemd-sysusers /etc/sysusers.d/powermon.conf
sed 's#/usr/bin/powermon#/usr/local/bin/powermon#' contrib/powermon.service | sudo tee /etc/systemd/system/powermon.service >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable powermon.service >/dev/null 2>&1
sudo systemctl restart powermon.service
systemctl --no-pager --lines=3 status powermon.service
