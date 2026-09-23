#!/bin/sh
# Build and install powermon system-wide and (re)start the recorder service. Run from the repo root.
set -eu
zig build -Drelease
sudo install -m 755 zig-out/bin/powermon /usr/local/bin/powermon
sudo install -m 644 contrib/powermon.service /etc/systemd/system/powermon.service
sudo systemctl daemon-reload
sudo systemctl enable powermon.service >/dev/null 2>&1
sudo systemctl restart powermon.service
systemctl --no-pager --lines=3 status powermon.service
