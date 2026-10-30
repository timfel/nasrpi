# nasrpi setup scripts

Idempotent, interactive setup scripts for the NAS Raspberry Pi.
Run them in order, as root, on the Pi:

```sh
sudo ./01_establish_mount_points.sh
sudo ./02_setup_emailproxy_mbsync_sendmail.sh
sudo ./03_setup_smartmontools.sh
sudo ./04_setup_rclone.sh
sudo ./05_setup_backup.sh
```

Run any of them again any time: everything checks first, changes only what's
missing, and asks before touching anything. Shared helpers live in `lib.sh`
(prompts, cron installer, package installer) — tweak there first.

## What each script does

| Script | Does |
|---|---|
| 01 | Puts your four disks into `/etc/fstab` (by UUID) at `/media/media`, `/media/media_parity`, `/media/nas`, `/media/nas_backup`. Guides you through picking disks by name/size, previews the fstab edit, backs up fstab first. |
| 02 | Installs `uv` + `emailproxy` (under `/opt/emailproxy`), a systemd service `emailproxy` (`--no-gui`) at boot, lets you add Gmail/Outlook/... accounts to its config, generates `/etc/mbsyncrc` that pulls **down only** into `/media/nas/Mail/<MAILBOX>`, weekly mbsync cron (skips when `/media/nas` unmounted), and sets up **msmtp** (plus `msmtp-mta`, which provides `/usr/sbin/sendmail`) so every script, smartd and cron job sends mail through `/etc/msmtprc` → emailproxy (localhost:1143) with the upstream mailer you pick. |
| 03 | smartmontools: monitors all disks **via `/dev/disk/by-uuid`**, short tests nightly / long weekly but **never spins up spun-down disks** (`-d maint`). smartd mails alerts itself; additionally every alert runs a `-M exec` handler (`/usr/local/bin/nasrpi-smartd-alert.sh`, device as argument, report on stdin) that logs to `/var/log/nasrpi-smart-alert.log` and **unmounts the failing disk** (`AUTO_UNMOUNT` at its top). **Zero tolerance:** `-I 5 -I 187 -I 197 -I 198` mails (and triggers the handler) the moment reallocated / uncorrected / pending sector counts change at all. |
| 04 | Installs rclone, runs `rclone config` so you can add remotes, then a weekly cron copying every remote into `/media/nas/<REMOTENAME>` (skips when unmounted). |
| 05 | Weekly cron: `rsync -a --delete /media/nas/ /media/nas_backup/`. Dry-runs first: if more than N% of dest files would be deleted it aborts and **sends you a report** instead. Also mails on failure. Skips when either mount is missing. |
| 06 | snapraid: content on `/media/media`, parity on `/media/media_parity`; generates `/etc/snapraid.conf` (asks which directories to protect), runs a snapraid dry-run and **guides you if the parity location is too small**, optionally builds initial parity, then a weekly cron doing `snapraid sync` + `snapraid scrub` (skips when unmounted) that mails you if scrub or sync reports any error. |

## Tweaking

- Cron schedules: rerun the script, or edit `/etc/cron.d/nasrpi-*` directly.
- Folder names for mail / remotes: `/opt/emailproxy/.nasrpi-mailmaps`,
  `/etc/nasrpi-rclone-maps` — plain `name=folder` files, edit freely.
- Backup knobs (`NOTIFY_EMAIL`, `DELETE_PCT`): top of
  `/usr/local/bin/nasrpi-backup.sh`.
- SMART alert behaviour: `AUTO_UNMOUNT` at the top of
  `/usr/local/bin/nasrpi-smartd-alert.sh` (set `no` for log/mail only);
  watched attributes are the `-I` list in `/etc/smartd.conf` (zero tolerance
  by default). Rerun 03 after adding or removing disks.
- Snapraid layout: `/etc/snapraid.conf` (edit freely; rerunning 06 leaves it
  alone once it exists).
- One-shot steps (add accounts, initial sync...) are remembered in
  `~/.nasrpi-state`; delete a line from `~/.nasrpi-state` to re-trigger a step.

## Notes / gotchas

- Needs Debian/Raspbian (`apt`) on the Pi; scripts exit cleanly elsewhere.
- emailproxy asks for app passwords per account (Gmail needs an app password).
  If `mbsync` complains about authentication, replace `Pass *` in
  `/etc/mbsyncrc` with the literal password.
- Outgoing mail always goes through msmtp (`/etc/msmtprc`, mode 600) via the
  `sendmail` compatibility shim from `msmtp-mta`. If emailproxy requires no
  password for localhost, leave the password prompt empty (`auth off`).
  Beware: a `~/.msmtprc` would override the system config for that user.
- 05's safety net compares proposed deletions against the dest file count;
  the first run against an empty destination deletes nothing.

## Testing without the Pi

```bash
./test_dryrun.sh          # runs every script with DRY_RUN=1 and fake paths
```

Nothing is written outside `/tmp` in dry-run mode; root actions are printed.
