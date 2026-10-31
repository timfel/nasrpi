#!/usr/bin/env python3
"""02_emailproxy.py -- read/seed an emailproxy config file, plus a login probe.

Helper for 02_setup_emailproxy_mbsync_sendmail.sh (python3 stdlib only).

Grounded in the real emailproxy.config layout used by simonrob/email-oauth2-proxy:

    [Server setup]                          # documentation-only section
    [IMAP-1993]                             # local IMAP port 1993 -> upstream 993
    server_address = imap.gmail.com
    server_port = 993
    local_address = 127.0.0.1

    [SMTP-1587]                             # local SMTP port 1587
    server_address = smtp-mail.outlook.com
    server_port = 587
    server_starttls = True
    local_address = 127.0.0.1

    [tim.felgentreff@oracle.com]            # <- an account: heading is the address
    permission_url = ...
    token_url = ...
    oauth2_scope = ...
    redirect_uri = http://localhost
    client_id = ...

So: accounts are sections whose heading is the e-mail address and that carry a
token_url; local ports come from [IMAP-n]/[SMTP-n] sections. nasrpi only ever
uses IMAP + SMTP over plain text on localhost (no TLS, no POP); everything
below reflects that.

Usage:
    02_emailproxy.py accounts <config> [--all]
        account addresses, one per line; sample/placeholder entries (the shipped
        example file's `*** your client id here ***` sections) are skipped unless
        --all is given. Sections that look like accounts but are only examples are
        written to stderr as "# sample: <name>" so callers can report them.

    02_emailproxy.py servers <config>
        one line per local IMAP/SMTP listener: <proto>\t<port>\t<local_address>

    02_emailproxy.py template
        print a starter config to stdout

    02_emailproxy.py imap-login --host HOST --port PORT --user ADDR --password PW
        log in to the proxy's local IMAP port and idle briefly; exit 0 if the
        proxy accepted the credentials (i.e. it has/obtained a token). Used to
        make emailproxy request an OAuth token during the external-auth flow.

Exit codes: 0 ok, 2 usage/missing/unparsable config, 3 nothing found,
            4 IMAP login rejected.
"""
import argparse
import configparser
import imaplib
import re
import sys

DOC_SECTIONS = ("server setup", "account setup", "advanced proxy configuration",
                "emailproxy", "")
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+$")            # account headings are addresses
SERVER_RE = re.compile(r"^(IMAP|SMTP)-(\d+)$", re.IGNORECASE)

TEMPLATE = """# emailproxy (Email OAuth 2.0 Proxy) configuration -- managed by nasrpi 02.
# Format: docs.python.org/library/configparser#supported-ini-file-structure
# Fully documented sample: github.com/simonrob/email-oauth2-proxy/blob/main/emailproxy.config
# Do NOT commit this file to a public repository: the proxy caches OAuth tokens here.

[Server setup]
documentation = Local servers: [IMAP-<port>] / [SMTP-<port>] say which local
    port the proxy listens on and which remote server it proxies. Email clients
    (mbsync, msmtp) connect to these local ports on 127.0.0.1 UNENCRYPTED with
    the local password set in 02; the proxy does the real TLS + OAuth 2.0
    conversation upstream. nasrpi uses IMAP and SMTP only (no POP).

[IMAP-1993]
server_address = imap.gmail.com
server_port = 993
local_address = 127.0.0.1

[SMTP-1587]
server_address = smtp.gmail.com
server_port = 465
local_address = 127.0.0.1

[Account setup]
documentation = One section per account, heading = the e-mail address. Required at
    minimum: token_url, oauth2_scope, client_id (plus permission_url for the normal
    authorisation-code flow). Uncomment one of the examples and put in your own
    client_id / client_secret, or add your provider's values.

# --- Office 365 / Outlook (also personal Outlook/Hotmail accounts) -------------
#[your.email@outlook.com]
#permission_url = https://login.microsoftonline.com/common/oauth2/v2.0/authorize
#token_url = https://login.microsoftonline.com/common/oauth2/v2.0/token
#oauth2_scope = https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send offline_access
#redirect_uri = http://localhost
#client_id = *** client id here ***

# --- Gmail ---------------------------------------------------------------------
#[your.email@gmail.com]
#permission_url = https://accounts.google.com/o/oauth2/auth
#token_url = https://oauth2.googleapis.com/token
#oauth2_scope = https://mail.google.com/
#redirect_uri = http://localhost
#client_id = *** client id here ***

[emailproxy]
delete_account_token_on_password_error = True
encrypt_client_secret_on_first_use = False
allow_catch_all_accounts = False
"""


def parse(path):
    """Parse an emailproxy config file (no % interpolation; multi-line values ok)."""
    cfg = configparser.ConfigParser(interpolation=None, delimiters=("=",))
    cfg.optionxform = str.lower
    try:
        with open(path, encoding="utf-8") as fh:
            cfg.read_file(fh)
    except OSError as err:
        sys.stderr.write(f"nasrpi: cannot read emailproxy config {path}: {err}\n")
        sys.exit(2)
    except configparser.Error as err:
        sys.stderr.write(f"nasrpi: cannot parse emailproxy config {path}: {err}\n")
        sys.exit(2)
    return cfg


def is_sample(cfg, section):
    """True if a section is still a shipped example (some value is `*** ... ***`).

    `documentation` is ignored: the real sample file writes
    `documentation = *** note: this server works for ... ***` inside server sections
    that are perfectly usable.
    """
    return any("***" in value for key, value in cfg[section].items()
               if key != "documentation")


def account_sections(cfg, include_samples=False):
    """Return (real_accounts, sample_accounts) from an emailproxy config.

    An account section is a section whose heading is an e-mail address and that
    carries a `token_url`. Catch-all headings such as [@domain.com] are not
    returned (they are not enumerable anyway).
    """
    real, sample = [], []
    for name in cfg.sections():
        heading = name.strip()
        if heading.lower() in DOC_SECTIONS or not EMAIL_RE.match(heading):
            continue                                  # docs / [IMAP-1993] / options
        if not cfg.has_option(name, "token_url"):
            continue                                  # not a proxyable account entry
        if is_sample(cfg, name):
            if include_samples:
                sample.append(heading)
        else:
            real.append(heading)
    return sorted(set(real), key=str.lower), sorted(set(sample), key=str.lower)


def server_rows(cfg):
    """Local proxy listeners declared as [IMAP-1993] / [SMTP-1587]."""
    rows = []
    for name in cfg.sections():
        match = SERVER_RE.match(re.sub(r"\s+", "", name))
        if not match:
            continue
        local_addr = (cfg[name].get("local_address") or "").strip() or "127.0.0.1"
        rows.append((match.group(1).upper(), int(match.group(2)), local_addr))
    return sorted(rows, key=lambda r: (r[0], r[1]))


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2
    cmd = argv[1]

    if cmd == "template":
        sys.stdout.write(TEMPLATE)
        return 0

    if cmd == "imap-login":
        return imap_login(argv[2:])

    if len(argv) < 3:
        sys.stderr.write(__doc__)
        return 2
    cfg = parse(argv[2])

    if cmd == "accounts":
        real, sample = account_sections(cfg, include_samples="--all" in argv[3:])
        print("\n".join(real))
        for name in sample:
            sys.stderr.write(f"# sample placeholder, not configured: {name}\n")
        return 0 if real else 3

    if cmd == "servers":
        rows = server_rows(cfg)
        for proto, port, local_addr in rows:
            print(f"{proto}\t{port}\t{local_addr}")
        return 0 if rows else 3

    sys.stderr.write(f"nasrpi: unknown emailproxy config command '{cmd}'\n")
    return 2


def imap_login(argv):
    """Log in via the proxy's local IMAP port; exit 0 only on success.

    emailproxy only asks for an OAuth token when a client actually logs in, so
    this doubles as the "wake the proxy up" trigger during --external-auth.
    A refused/failed login exits 4; connection problems exit 2.
    """
    parser = argparse.ArgumentParser(prog="02_emailproxy.py imap-login",
                                     description="log in to emailproxy's local IMAP port")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", default="1993")
    parser.add_argument("--user", required=False)
    parser.add_argument("--password", default="")
    opts = parser.parse_args(argv)
    if not (opts.host and opts.port and opts.user and opts.password):
        sys.stderr.write("nasrpi: imap-login needs --host, --port, --user, --password\n")
        return 2
    try:
        conn = imaplib.IMAP4(opts.host, int(opts.port), timeout=120)
    except (OSError, imaplib.IMAP4.error) as err:
        sys.stderr.write(f"nasrpi: cannot reach emailproxy at {opts.host}:{opts.port}: {err}\n")
        return 2
    try:
        conn.login(opts.user, opts.password or "")
    except imaplib.IMAP4.abort as err:      # connection dropped mid-login (proxy busy)
        sys.stderr.write(f"nasrpi: emailproxy connection dropped during login for "
                         f"{opts.user}: {err}\n")
        return 2
    except imaplib.IMAP4.error as err:      # credentials refused / no token yet
        sys.stderr.write(f"nasrpi: emailproxy rejected login for {opts.user}: {err}\n")
        return 4
    except OSError as err:
        sys.stderr.write(f"nasrpi: IMAP conversation with emailproxy failed: {err}\n")
        return 2
    try:
        conn.list()                              # touch the upstream server a little
        conn.logout()
    except Exception:                            # noqa: BLE001 - logout is best-effort
        pass
    print(f"imap login ok: {opts.user}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
