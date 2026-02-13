# MySQL Backup Service

A portable, zero-dependency MySQL backup solution that runs on any Linux server. Dumps databases, compresses them, uploads to S3-compatible storage, and automatically prunes old backups.

## Features

- **Universal** — works on Ubuntu, Debian, CentOS, RHEL, Fedora, Arch, Alpine, SUSE
- **S3-compatible** — AWS S3, DigitalOcean Spaces, MinIO, Backblaze B2, Wasabi, etc.
- **Configurable naming** — use `{db}`, `{date}`, `{time}`, `{timestamp}`, `{hostname}` placeholders
- **Auto-retention** — keeps N backups per database, prunes the rest
- **Systemd timer** — reliable scheduling with persistent catch-up after downtime
- **Failure alerts** — optional Slack/Discord webhook notifications
- **Safe** — file locking prevents overlapping runs, `--single-transaction` for InnoDB

## Quick Start

```bash
# 1. Clone / copy to your server
git clone https://github.com/Nemanja02/database-backup.git /opt/mysql-backup-service
cd /opt/mysql-backup-service

# 2. Install (requires root) — will prompt for config if .env doesn't exist
sudo bash install.sh

# Or generate .env separately first, then install:
bash generate-env.sh
sudo bash install.sh
```

That's it. Backups will run on the schedule you defined in `.env`.

## Configuration (.env)

| Variable | Description | Example |
|---|---|---|
| `MYSQL_HOST` | MySQL server address | `localhost` |
| `MYSQL_PORT` | MySQL port | `3306` |
| `MYSQL_USER` | MySQL user | `root` |
| `MYSQL_PASSWORD` | MySQL password | `s3cur3pass` |
| `MYSQL_DATABASES` | Comma-separated list or `ALL` | `app_db,analytics` |
| `BACKUP_NAME_PATTERN` | Filename pattern | `{hostname}_{db}_{date}_{time}` |
| `S3_BUCKET` | S3 bucket name | `my-backups` |
| `S3_PATH` | Path prefix inside bucket | `backups/mysql` |
| `S3_ENDPOINT` | S3 endpoint URL | `https://s3.amazonaws.com` |
| `AWS_ACCESS_KEY_ID` | S3 access key | — |
| `AWS_SECRET_ACCESS_KEY` | S3 secret key | — |
| `AWS_DEFAULT_REGION` | AWS region | `us-east-1` |
| `BACKUP_INTERVAL_HOURS` | Hours between backups | `24` |
| `BACKUP_RETENTION_COUNT` | Backups to keep per DB | `7` |
| `NOTIFY_WEBHOOK_URL` | Slack/Discord webhook (optional) | — |
| `NOTIFY_TYPE` | `slack` or `discord` | `slack` |
| `LOG_FILE` | Log file path | `/var/log/mysql-backup-service.log` |

## S3 Storage Layout

Backups are organized per database:

```
s3://my-backups/backups/mysql/
├── app_db/
│   ├── web1_app_db_2026-02-10_03-00-00.sql.gz
│   ├── web1_app_db_2026-02-11_03-00-00.sql.gz
│   └── web1_app_db_2026-02-12_03-00-00.sql.gz
└── analytics/
    ├── web1_analytics_2026-02-10_03-00-00.sql.gz
    └── web1_analytics_2026-02-11_03-00-00.sql.gz
```

## Commands

```bash
# Run a backup manually
sudo /opt/mysql-backup-service/mysql-backup.sh

# Check timer status
systemctl status mysql-backup.timer

# View next scheduled run
systemctl list-timers mysql-backup.timer

# Tail logs
tail -f /var/log/mysql-backup-service.log

# Stop the timer
sudo systemctl stop mysql-backup.timer

# Uninstall (keeps files, removes systemd units)
sudo /opt/mysql-backup-service/uninstall.sh
```

## Restoring a Backup

```bash
# Download from S3
aws s3 cp s3://my-backups/backups/mysql/app_db/web1_app_db_2026-02-12_03-00-00.sql.gz .

# Restore
gunzip -c web1_app_db_2026-02-12_03-00-00.sql.gz | mysql -u root -p app_db
```

## License

MIT