# Automated PostgreSQL Backup, Recovery & Integrity Verification

Automation of PostgreSQL backup, restore, and data integrity verification.

## Project Goal

Build a system that:
- Deploys PostgreSQL using Docker;
- Creates a test database with sample data;
- Automatically performs backups (using `pg_dump`);
- Allows database recovery after failure or data loss;
- Verifies that after restoration the data is correct again (integrity check).


## Tech Stack

- PostgreSQL 16
- Docker & Docker Compose
- Bash
- systemd / cron
- Git

## Repository Structure
```
project/
│
├── docker-compose.yml
├── .env
│
├── init/
│   └── init.sql
│
├── scripts/
│   ├── backup.sh
│   ├── restore.sh
│   ├── verify.sh
│   └── verify.sql
│
├── backups/
│
├── logs/
│   ├── backup.log
│   └── restore.log
│
├── systemd/
│   ├── backup.service
│   └── backup.timer
│
├── tests/
│   └── tests.md
│
└── README.md
```

## Getting started

### 1. Clone the repository
```bash
git clone <url>
cd project
```

2. Configure environment
```bash
cp .env.example .env
# Edit .env (see .env.example)
```

3. Start PostgreSQL
```bash
docker compose up -d
```

4. Create a backup
```bash
./scripts/backup.sh
```
5. Verify integrity
```bash
./scripts/verify.sh
```
6. Restore from backup
```bash
./scripts/restore.sh backups/backup_file.sql.gz
```

## Usage
### Manual commands
./scripts/backup.sh — create a backup (stored in backups/ with timestamp)

./scripts/restore.sh <file> — restore database from the given dump

./scripts/verify.sh — run integrity checks (compare with baseline)

### Automation (systemd)
Copy systemd/backup.service and backup.timer to /etc/systemd/system/

Set absolute paths inside the files

Run:

```bash
sudo systemctl daemon-reload
sudo systemctl enable backup.timer
sudo systemctl start backup.timer
```

Logs are stored in logs/backup.log and logs/restore.log.

