#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
script=$root/deploy/vn/scripts/restore-drill.sh
fail() { printf 'FAIL restore drill: %s\n' "$1" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin" "$work/tmp" "$work/fixture/etc/aboutme/secrets"

key_id=AKIAFAKEKEYID0123456
key_secret=fakeSecretAccessKey/0123456789abcdef
cipher=fakecipherpass0123456789abcdef
printf '%s' "$key_id" >"$work/fixture/etc/aboutme/secrets/backup-access-key-id"
printf '%s' "$key_secret" >"$work/fixture/etc/aboutme/secrets/backup-secret-access-key"
printf '%s' "$cipher" >"$work/fixture/etc/aboutme/secrets/pgbackrest-cipher-pass"
printf 'unrelated' >"$work/fixture/etc/aboutme/secrets/totp-key-a"
tar -C "$work/fixture" -cf "$work/archive.tar" etc
printf 'age-identity\n' >"$work/identity"

cat >"$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >>"$STUB_LOG"
printf 'ZW5jcnlwdGVk\n'
STUB
cat >"$work/bin/age" <<'STUB'
#!/usr/bin/env bash
printf 'age\n' >>"$STUB_LOG"
cat "$STUB_ARCHIVE"
STUB
cat >"$work/bin/podman" <<'STUB'
#!/usr/bin/env bash
printf 'podman %s\n' "$*" >>"$STUB_LOG"
[[ $1 == run ]] || exit 0
for arg in "$@"; do
  case $arg in
    *:/run/drill-secrets:ro)
      dir=${arg%%:*}
      printf '%s\n' "$dir" >"$STUB_SECRET_DIR"
      [[ $(cat "$dir/backup-access-key-id") == "$STUB_KEY_ID" ]] || exit 9
      [[ -z $(find "$dir" -name 'totp*') ]] || exit 9
      ;;
  esac
done
printf 'restore ran\n'
exit "${STUB_RUN_RC:-0}"
STUB
chmod +x "$work/bin/"*

run_drill() {
  : >"$work/log"
  rm -f "$work/secret-dir" "$work/out" "$work/err"
  rc=0
  PATH=$work/bin:$PATH TMPDIR=$work/tmp STUB_LOG=$work/log STUB_ARCHIVE=$work/archive.tar \
    STUB_SECRET_DIR=$work/secret-dir STUB_KEY_ID=$key_id AGE_IDENTITY=$identity \
    bash "$script" "$@" >"$work/out" 2>"$work/err" || rc=$?
}
assert_clean() {
  for value in "$key_id" "$key_secret" "$cipher"; do
    if grep -rqF -- "$value" "$work/out" "$work/err" "$work/log"; then fail "$1: a secret value reached output or a command line"; fi
  done
  [[ -z $(ls -A "$work/tmp") ]] || fail "$1: temporary directory left behind"
}

identity=$work/identity
run_drill
[[ $rc == 0 ]] || fail "success run exited $rc: $(cat "$work/err")"
[[ $(tail -n1 "$work/out") == PASS ]] || fail 'success run did not end with PASS'
grep -q '^gh api .*aboutme-infra/contents/deploy/vn/secrets/host-secrets.age' "$work/log" || fail 'archive was not fetched from aboutme-infra'
grep -q '^podman run .*ubuntu:24.04@sha256:' "$work/log" || fail 'image is not pinned by digest'
assert_clean 'success run'

STUB_RUN_RC=1 run_drill
[[ $rc != 0 ]] || fail 'failing restore exited 0'
! grep -q '^PASS$' "$work/out" || fail 'failing restore printed PASS'
[[ -s $work/secret-dir && ! -e $(cat "$work/secret-dir") ]] || fail 'secret directory survived a failed restore'
grep -q '^podman rm -f aboutme-restore-drill-' "$work/log" || fail 'container was not removed after a failed restore'
grep -q '^podman volume rm -f aboutme-restore-drill-' "$work/log" || fail 'volume was not removed after a failed restore'
assert_clean 'failing restore'

printf 'local-archive' >"$work/local.age"
run_drill "$work/local.age"
[[ $rc == 0 ]] || fail 'local archive run failed'
! grep -q '^gh ' "$work/log" || fail 'gh was called despite a local archive'

identity=$work/missing-identity
run_drill
[[ $rc != 0 ]] || fail 'ran without an age identity'
! grep -qE '^(gh|age|podman)' "$work/log" || fail 'tools ran without an age identity'

echo 'restore drill tests passed'
