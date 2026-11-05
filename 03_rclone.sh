#!/usr/bin/env bash

curl https://rclone.org/install.sh | sudo bash   # into /usr/local/bin; apt's rclone is stale

echo "current remotes:"
sudo rclone listremotes

sudo rclone config

echo "remotes now:"
sudo rclone listremotes
