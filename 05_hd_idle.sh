#!/usr/bin/env bash

sudo apt install hd-idle

cat <<'EOF' | sudo tee /etc/default/hd-idle
START_HD_IDLE=true
HD_IDLE_OPTS="-i 1800 -l /var/log/hd-idle.log"
EOF

sudo systemctl enable hd-idle
sudo systemctl restart hd-idle
