#!/usr/bin/env bash
set -euo pipefail

image=docker.io/library/ubuntu:24.04@sha256:9c7f200c07e3d4a03e7249d2c16bf66a51120fb876aa2242cf31451412543289
infra_repo=dannyota/aboutme-infra
infra_path=deploy/vn/secrets/host-secrets.age
secret_names=(backup-access-key-id backup-secret-access-key pgbackrest-cipher-pass)

die() {
  printf 'restore-drill: %s\n' "$*" >&2
  exit 1
}

pin() {
  local value
  value=$(sed -n "s/^$1=//p" "$install_sh")
  [[ -n $value ]] || die "$1 is missing from install.sh"
  printf '%s' "$value"
}

drill_inner() {
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  local bin=/usr/lib/postgresql/18/bin mode dir label target start seconds goose app table count rows

  as_postgres() { setpriv --reuid=postgres --regid=postgres --init-groups "$@"; }
  sql() { as_postgres psql -X -q -At -v ON_ERROR_STOP=1 -h /run/postgresql -d aboutme "$@"; }

  mkdir -p /etc/postgresql-common /etc/apt/keyrings
  printf 'create_main_cluster = false\n' >/etc/postgresql-common/createcluster.conf
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends ca-certificates gnupg >/dev/null
  [[ $(gpg --show-keys --with-colons /drill/pgdg.asc | awk -F: '$1 == "pub" { want = 1; next } want && $1 == "fpr" { print $10; want = 0 }') == "$PGDG_SIGNER_FPR" ]] ||
    { echo 'PGDG key fingerprint mismatch' >&2; exit 1; }
  install -m 0644 /drill/pgdg.asc /etc/apt/keyrings/postgresql.asc
  echo 'deb [signed-by=/etc/apt/keyrings/postgresql.asc] https://apt.postgresql.org/pub/repos/apt noble-pgdg main' >/etc/apt/sources.list.d/pgdg.list
  echo 'deb [signed-by=/etc/apt/keyrings/postgresql.asc] https://apt-archive.postgresql.org/pub/repos/apt noble-pgdg-archive main' >>/etc/apt/sources.list.d/pgdg.list
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends --allow-downgrades \
    "postgresql-common=$POSTGRESQL_COMMON_VERSION" "postgresql-client-common=$POSTGRESQL_COMMON_VERSION" >/dev/null
  apt-get install -y -qq --no-install-recommends --allow-downgrades \
    "postgresql-18=$POSTGRESQL_VERSION" "postgresql-client-18=$POSTGRESQL_VERSION" \
    "libpq5=$POSTGRESQL_VERSION" "pgbackrest=$PGBACKREST_VERSION" >/dev/null
  install -d -o postgres -g postgres -m 0755 /run/postgresql

  PGBACKREST_REPO1_S3_KEY=$(</run/drill-secrets/backup-access-key-id)
  PGBACKREST_REPO1_S3_KEY_SECRET=$(</run/drill-secrets/backup-secret-access-key)
  PGBACKREST_REPO1_CIPHER_PASS=$(</run/drill-secrets/pgbackrest-cipher-pass)
  export PGBACKREST_REPO1_S3_KEY PGBACKREST_REPO1_S3_KEY_SECRET PGBACKREST_REPO1_CIPHER_PASS

  for mode in latest time; do
    dir=/restore/$mode
    install -d -o postgres -g postgres -m 0700 "$dir"
    local args=(--config=/drill/pgbackrest.conf "--stanza=$STANZA" "--pg1-path=$dir")
    target=latest
    if [[ $mode == time ]]; then
      target=$(date -u -d '24 hours ago' '+%Y-%m-%d %H:%M:%S+00')
      args+=(--type=time "--target=$target" --target-action=promote)
    fi
    as_postgres pgbackrest "${args[@]}" restore >/dev/null
    label=$(sed -n 's/^LABEL: //p' "$dir/backup_label")

    start=$SECONDS
    as_postgres "$bin/pg_ctl" -D "$dir" -l "/tmp/postgres-$mode.log" -w -t 900 \
      -o '-c config_file=/drill/pg/conf.d/90-aboutme.conf -c hba_file=/drill/pg/pg_hba.conf -c ident_file=/drill/pg/pg_ident.conf -c archive_mode=off' \
      start >/dev/null
    until [[ $(sql -c 'SELECT pg_is_in_recovery()' 2>/dev/null || true) == f ]]; do
      ((SECONDS - start < 900)) || { echo "recovery did not finish ($mode)" >&2; exit 1; }
      sleep 2
    done
    seconds=$((SECONDS - start))

    goose=$(sql -c 'SELECT max(version_id) FROM goose_db_version')
    [[ $goose =~ ^[0-9]+$ ]] || { echo "no goose version ($mode)" >&2; exit 1; }
    app=$(printf 'SET ROLE aboutme_app;\nSELECT count(*) FROM resumes;\n' | sql)
    [[ $app =~ ^[0-9]+$ ]] || { echo "aboutme_app read failed ($mode)" >&2; exit 1; }
    rows=$(sql -F ' ' -c "SELECT table_name, (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE' ORDER BY 1")
    [[ -n $rows ]] || { echo "no tables in public ($mode)" >&2; exit 1; }

    printf '== %s restore: backup %s, target %s, recovery %ss\n' "$mode" "$label" "$target" "$seconds"
    printf 'goose version %s\n' "$goose"
    while read -r table count; do
      [[ $table =~ ^[a-z0-9_]+$ && $count =~ ^[0-9]+$ ]] || { echo "bad count row ($mode)" >&2; exit 1; }
      printf 'rows %s %s\n' "$table" "$count"
    done <<<"$rows"
    printf 'aboutme_app resumes %s\n' "$app"
    as_postgres "$bin/pg_ctl" -D "$dir" -m fast -w stop >/dev/null
  done
}

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
install_sh=$root/deploy/vn/host/install.sh
pgbackrest_conf=$root/deploy/vn/host/etc/pgbackrest/pgbackrest.conf
pgdg_key=$root/deploy/vn/host/keys/pgdg.asc
pg_config_dir=$root/deploy/vn/host/etc/postgresql/18/main

(($# <= 1)) || die 'usage: restore-drill.sh [host-secrets.age]'
source_file=${1:-${HOST_SECRETS_FILE:-}}
identity=${AGE_IDENTITY:-$HOME/.config/aboutme/vn/infra-age.key}
[[ -f $identity ]] || die "age identity not found: $identity"
for file in "$install_sh" "$pgbackrest_conf" "$pgdg_key" "$pg_config_dir/pg_hba.conf"; do
  [[ -f $file ]] || die "missing $file"
done

POSTGRESQL_VERSION=$(pin POSTGRESQL_VERSION)
POSTGRESQL_COMMON_VERSION=$(pin POSTGRESQL_COMMON_VERSION)
PGBACKREST_VERSION=$(pin PGBACKREST_VERSION)
PGDG_SIGNER_FPR=$(pin PGDG_SIGNER_FPR)
STANZA=$(awk -F'[][]' '/^\[/ && $2 != "global" { print $2; exit }' "$pgbackrest_conf")
[[ -n $STANZA ]] || die 'no stanza in pgbackrest.conf'
export POSTGRESQL_VERSION POSTGRESQL_COMMON_VERSION PGBACKREST_VERSION PGDG_SIGNER_FPR STANZA

work=$(mktemp -d)
name=aboutme-restore-drill-$$
cleanup() {
  podman rm -f "$name" >/dev/null 2>&1 || true
  podman volume rm -f "$name" >/dev/null 2>&1 || true
  rm -rf -- "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
chmod 0700 "$work"
mkdir -m 0700 "$work/secrets"

if [[ -z $source_file ]]; then
  source_file=$work/host-secrets.age
  gh api "repos/$infra_repo/contents/$infra_path" --jq .content | base64 -d >"$source_file"
fi
[[ -s $source_file ]] || die 'host secrets archive is empty'

members=()
for secret in "${secret_names[@]}"; do members+=("etc/aboutme/secrets/$secret"); done
age -d -i "$identity" "$source_file" | tar -xf - -C "$work/secrets" --strip-components=3 "${members[@]}"
for secret in "${secret_names[@]}"; do
  [[ -s $work/secrets/$secret ]] || die "archive lacks $secret"
done

podman run --name "$name" \
  -v "$name:/restore" \
  -v "$work/secrets:/run/drill-secrets:ro" \
  -v "$pgbackrest_conf:/drill/pgbackrest.conf:ro" \
  -v "$pgdg_key:/drill/pgdg.asc:ro" \
  -v "$pg_config_dir:/drill/pg:ro" \
  -e POSTGRESQL_VERSION -e POSTGRESQL_COMMON_VERSION -e PGBACKREST_VERSION -e PGDG_SIGNER_FPR -e STANZA \
  "$image" bash -c "$(declare -f drill_inner); drill_inner"
printf 'PASS\n'
