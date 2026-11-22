# Restore drill

Status: accepted by the owner on 2026-11-22. Replaces the temporary-vServer drill and its networking design.

## Goal

Prove that production can be rebuilt from what lives off the host: the encrypted pgBackRest repository in HCM04 and the age-encrypted host secrets in the private `aboutme-infra` repository. Production holds about 44 MB of data, so the drill runs on the owner's laptop.

## Procedure

`deploy/vn/scripts/restore-drill.sh` runs on the laptop and touches nothing in production:

1. Read `deploy/vn/secrets/host-secrets.age` from `aboutme-infra`, decrypt it with the laptop's age identity, and take only the backup access key, secret key, and cipher passphrase. Values stay in memory or in a private temporary directory and never reach output.
2. Start one throwaway Podman container with PostgreSQL 18 and the pgBackRest version that production pins in `deploy/vn/host/install.sh`, using the repository settings from `deploy/vn/host/etc/pgbackrest/pgbackrest.conf`.
3. Restore twice into fresh data directories: the latest backup with full WAL replay, then a point-in-time target 24 hours earlier. Start PostgreSQL with `archive_mode=off` each time.
4. Check each restore: the goose version, row counts per table in `public`, and a read as `aboutme_app` on `resumes`.
5. Remove the container, its volumes, and the temporary directory, also on failure.

Output is count-only: backup label, recovery target, recovery time, goose version, and table counts. It never prints rows, keys, or connection strings.

## Cadence and record

Run it quarterly and after any change to the PostgreSQL or pgBackRest pins. Record the date, backup label, recovery times, and pass or fail in [Vietnam operations evidence](../plans/traceability/vietnam-operations.md#restore-prerequisites).

## What it skips

- No cloud server, network isolation, journal, or controller fencing: the laptop already holds these keys in the age copy, and a restore only reads the repository.
- It uses the host's backup key, not a separate read-only key. A per-run reader key adds bucket policy work for little gain at this scale.
- It does not run the application, CrowdSec, or the host's reset procedure; those keep their own tests.
