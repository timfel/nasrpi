#!/usr/bin/env bash

## runtime packages
sudo apt install isync msmtp msmtp-mta ca-certificates curl libsasl2-modules-kdexoauth2 gnupg

# build pizauth
if ! which pizauth.bin; then
    echo "Building pizauth"
    sudo apt install build-essential pkg-config git
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
    export PATH="$HOME/.cargo/bin:$PATH"
    cargo --version
    stage="$PWD/.tmp/pizauth-root"
    rm -rf "$stage"
    cargo install --locked --git https://github.com/ltratt/pizauth --tag pizauth-1.1.1 --root "$stage" pizauth
    sudo cp "$stage"/bin/pizauth /usr/bin/pizauth.bin
    /usr/bin/pizauth.bin --version
    rm -rf "$stage"
fi

cat <<'EOF' | sudo tee /usr/bin/pizauth
#!/bin/sh
export SHELL=sh
export XDG_RUNTIME_DIR=/run/pizauth
mkdir -p $XDG_RUNTIME_DIR || true
pizauth.bin "$@"
EOF
sudo chmod +x /usr/bin/pizauth

## token storage, encrypted with a gpg key derived from the local router
sudo mkdir -p /var/lib/pizauth/gnupg

cat <<'EOF' | sudo tee /usr/bin/pizauth-udn
#!/bin/sh
curl -fsS -m 5 http://fritz.box:49000/igddesc.xml | awk 'match($0, /<UDN>[^<]+<\/UDN>/) { s = substr($0, RSTART + 5, RLENGTH - 11); print s; exit }'
EOF
sudo chmod +x /usr/bin/pizauth-udn

cat <<'EOF' | sudo tee /usr/bin/pizauth-seal
#!/bin/sh
set -eu
u=$(/usr/bin/pizauth-udn)
[ -n "$u" ] || { echo "pizauth-seal: no UPnP UDN -- not in your LAN?" >&2; exit 1; }
kf=$(mktemp); chmod 600 "$kf"; trap 'rm -f "$kf"' EXIT
printf '%s' "nasrpi-pizauth-v1|$u" | sha256sum | cut -d' ' -f1 > "$kf"
gpg --batch --no-tty --homedir /var/lib/pizauth/gnupg --pinentry-mode loopback --passphrase-file "$kf" --symmetric --cipher-algo AES256 -o -
EOF
sudo chmod +x /usr/bin/pizauth-seal

cat <<'EOF' | sudo tee /usr/bin/pizauth-unseal
#!/bin/sh
set -eu
u=$(/usr/bin/pizauth-udn)
[ -n "$u" ] || { echo "pizauth-unseal: no UPnP UDN -- not in your LAN?" >&2; exit 1; }
kf=$(mktemp); chmod 600 "$kf"; trap 'rm -f "$kf"' EXIT
printf '%s' "nasrpi-pizauth-v1|$u" | sha256sum | cut -d' ' -f1 > "$kf"
gpg --batch --quiet --no-tty --homedir /var/lib/pizauth/gnupg --pinentry-mode loopback --passphrase-file "$kf" -d
EOF
sudo chmod +x /usr/bin/pizauth-unseal

## just check the LAN key works
sudo pizauth-udn || echo "WARNING: could not read the gateway UPnP UDN -- tokens could never be unsealed"
echo 'round trip' | sudo pizauth-seal | sudo pizauth-unseal | grep -q 'round trip' && echo "seal/unseal round trip ok" || echo "WARNING: seal/unseal round trip failed"

## pizauth.conf
# dump: seal then mv, so a failed seal cannot destroy the previous good dump
# restore: sleep because the server needs a little to accept connections sometimes
cat <<'EOF' | sudo tee /etc/pizauth.conf
http_listen = "127.0.0.1:19024";
token_event_cmd = "/usr/bin/pizauth dump | /usr/bin/pizauth-seal > /var/lib/pizauth/tokens.dump.gpg.new && mv -f /var/lib/pizauth/tokens.dump.gpg.new /var/lib/pizauth/tokens.dump.gpg";
startup_cmd = "test -s /var/lib/pizauth/tokens.dump.gpg && sleep 4 && /usr/bin/pizauth-unseal < /var/lib/pizauth/tokens.dump.gpg | /usr/bin/pizauth restore";
auth_notify_cmd = "logger -t pizauth -p mail.warning \"pizauth needs sign-in for $PIZAUTH_ACCOUNT: $PIZAUTH_URL\"";
error_notify_cmd = "logger -t pizauth -p mail.err \"pizauth error for $PIZAUTH_ACCOUNT: $PIZAUTH_MSG\"";

account "timfelgentreff_gmail_com" {
    client_id = "406964657835-aq8lmia8j95dhl1a2bvharmfk3t1hgqj.apps.googleusercontent.com";
    client_secret = "kSmqreRr0qwBWJgbf5Y-PjSU";
    auth_uri = "https://accounts.google.com/o/oauth2/auth";
    token_uri = "https://oauth2.googleapis.com/token";
    scopes = ["https://mail.google.com/"];
    auth_uri_fields = { "login_hint": "timfelgentreff@gmail.com" };
}

account "timfelgentreff_hotmail_com" {
    client_id = "9e5f94bc-e8a4-4e73-b8be-63364c29d753";
    auth_uri = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize";
    token_uri = "https://login.microsoftonline.com/common/oauth2/v2.0/token";
    scopes = ["https://outlook.office.com/IMAP.AccessAsUser.All", "https://outlook.office.com/SMTP.Send", "offline_access"];
    auth_uri_fields = { "login_hint": "timfelgentreff@hotmail.com" };
}
EOF
sudo chmod 600 /etc/pizauth.conf

## systemd file
cat <<'EOF' | sudo tee /etc/systemd/system/pizauth.service
[Unit]
Description=pizauth OAuth2 token manager
Documentation=https://github.com/ltratt/pizauth
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/pizauth server -c /etc/pizauth.conf -d
ExecReload=/usr/bin/pizauth reload
ExecStop=/usr/bin/pizauth shutdown
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now pizauth
sudo systemctl restart pizauth

sudo pizauth reload && echo "pizauth server is answering" \
        || { echo "WARNING: pizauth is not answering:"; sudo journalctl -u pizauth -n 10 --no-pager; }

## mail goes into /media/nas/Mail
mkdir -p /media/nas/Mail

## mbsync
cat <<'EOF' | sudo tee /etc/mbsyncrc
IMAPAccount timfelgentreff_gmail_com
Host imap.gmail.com
Port 993
User timfelgentreff@gmail.com
AuthMechs XOAUTH2
PassCmd "/usr/bin/pizauth show timfelgentreff_gmail_com"
SSLType IMAPS
CertificateFile /etc/ssl/certs/ca-certificates.crt

IMAPStore timfelgentreff_gmail_com-remote
Account timfelgentreff_gmail_com

MaildirStore timfelgentreff_gmail_com-local
SubFolders Verbatim
Path /media/nas/Mail/timfelgentreff_gmail_com/
Inbox /media/nas/Mail/timfelgentreff_gmail_com

Channel timfelgentreff_gmail_com
Far :timfelgentreff_gmail_com-remote:
Near :timfelgentreff_gmail_com-local:
Patterns "[Google Mail]/All Mail"
SyncState *
Create Near
Remove Near
Expunge Near
CopyArrivalDate yes
Sync Pull

IMAPAccount timfelgentreff_hotmail_com
Host outlook.office365.com
Port 993
User timfelgentreff@hotmail.com
AuthMechs XOAUTH2
PassCmd "/usr/bin/pizauth show timfelgentreff_hotmail_com"
SSLType IMAPS
CertificateFile /etc/ssl/certs/ca-certificates.crt

IMAPStore timfelgentreff_hotmail_com-remote
Account timfelgentreff_hotmail_com

MaildirStore timfelgentreff_hotmail_com-local
SubFolders Verbatim
Path /media/nas/Mail/timfelgentreff_hotmail_com/
Inbox /media/nas/Mail/timfelgentreff_hotmail_com

Channel timfelgentreff_hotmail_com
Far :timfelgentreff_hotmail_com-remote:
Near :timfelgentreff_hotmail_com-local:
Patterns *
SyncState *
Create Near
Remove Near
Expunge Near
CopyArrivalDate yes
Sync Pull
EOF

## msmtprc
cat <<'EOF' | sudo tee /etc/msmtprc
defaults
auth xoauth2
tls on
tls_trust_file /etc/ssl/certs/ca-certificates.crt

account timfelgentreff_gmail_com
host smtp.gmail.com
port 587
from timfelgentreff@gmail.com
user timfelgentreff@gmail.com
tls_starttls on
passwordeval /usr/bin/pizauth show timfelgentreff_gmail_com

account timfelgentreff_hotmail_com
host smtp.office365.com
port 587
from timfelgentreff@hotmail.com
user timfelgentreff@hotmail.com
tls_starttls on
passwordeval /usr/bin/pizauth show timfelgentreff_hotmail_com

account default : timfelgentreff_gmail_com
EOF

## sign in
for account in timfelgentreff_gmail_com timfelgentreff_hotmail_com; do
    if sudo pizauth show "$account" >/dev/null 2>&1; then
        echo "$account: token present"
        continue
    fi
    url=$(sudo pizauth show "$account" 2>&1 >/dev/null | sed -n 's/.*with URL \(https[^ "]*\).*/\1/p' | head -1)
    echo
    echo "sign in for $account"
    echo "  - ssh -N -L 127.0.0.1:19024:127.0.0.1:19024 ${USER}@$(hostname)"
    echo "  - open $url"
    echo
    echo "  Waiting up to 5 minutes (ctrl-c gives up)"
    sleep 25
    for i in $(seq 55); do
        sleep 5
        sudo pizauth show "$account" >/dev/null 2>&1 && break
    done
    if sudo pizauth show "$account" >/dev/null 2>&1; then
        echo "$account: token is in pizauth"
    else
        echo "WARNING: $account still has no token -- redo this sign-in later with: sudo pizauth show $account"
    fi
done

## verify
sudo mbsync -c /etc/mbsyncrc -l
echo
read -r -p "Send a test mail to timfelgentreff@gmail.com via sendmail? [y/N] " reply
if [ "$reply" = "y" ] || [ "$reply" = "Y" ]; then
    printf 'Subject: nasrpi test mail\n\nSent by 02_email.sh through pizauth + msmtp.\n' \
        | sudo sendmail -a timfelgentreff_gmail_com timfelgentreff@gmail.com \
        && echo "test mail handed to sendmail"
fi
