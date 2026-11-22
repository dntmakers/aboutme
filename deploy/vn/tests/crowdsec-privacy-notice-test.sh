#!/usr/bin/env bash
set -euo pipefail; export LC_ALL=C
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
fail() { printf 'FAIL notice host %s\n' "$1" >&2; exit 1; }
primitive=$root/deploy/vn/host/crowdsec-privacy-notice-host.sh; wrapper=$root/deploy/vn/scripts/crowdsec-privacy-notice.sh
[[ -f $primitive && -f $wrapper ]] || fail 'missing implementation'
legacy_fields=(LEGACY_RELEASE_TAG LEGACY_RELEASE_SHA256 LEGACY_SERVER_IMAGE LEGACY_WEB_IMAGE LEGACY_FENCE_SHA256 LEGACY_DEPLOY_HOST_SHA256 LEGACY_DEPLOY_SAFETY_SHA256)
for field in "${legacy_fields[@]}"; do grep -Eq "^readonly $field='[^']+'$" "$primitive" || fail 'missing closed legacy pin'; done
[[ $(id -u) == 0 ]] || fail 'isolated root runner required'
grep -Fq -- '--network=none' "$wrapper" || fail 'owner command network'; grep -Eq -- '--memory(=|[[:space:]])(256[mM]|268435456)' "$wrapper" || fail 'owner command memory'
grep -Fq 'aboutme_app' "$wrapper" || fail 'owner command database identity'; grep -Fq '/run/postgresql' "$wrapper" || fail 'owner command database socket'
grep -Fq 'server_image' "$wrapper" || fail 'owner command release pin'; grep -Fq 'privacy-notice:/var/lib/aboutme/privacy-notice:ro' "$wrapper" || fail 'owner authority directory mount'
grep -Fq 'authorize-send' "$wrapper" || fail 'explicit send authority action'; grep -Fq 'content_sha256' "$wrapper" || fail 'owner manifest validation'
grep -Fq 'publication_date' "$wrapper" || fail 'owner publication validation'; grep -Fq 'expected_count' "$wrapper" || fail 'owner aggregate validation'
grep -Fq 'accepted_count' "$wrapper" || fail 'owner completion validation'; grep -Fq 'capture' "$wrapper" || fail 'owner capture interruption marker'
grep -Fq 'adopt' "$primitive" || fail 'explicit legacy adoption action'; installer=$root/deploy/vn/host/install.sh
awk '
  /crowdsec-privacy-notice-host.sh/ && !helper {helper=NR}; /workload-lock.sh/ && !workload {workload=NR}
  /fence.sh/ && !fence {fence=NR}
  /if \[ "\$only" = postgres \]/ {postgres=NR}; END {exit !(helper && workload && fence && postgres && helper<postgres && workload<postgres && fence<postgres)}
' "$installer" || fail 'postgres installer skipped shared dependencies'
work=$(mktemp -d /run/aboutme-notice-test.XXXXXX)
stub() { local target=$1; { printf '#!/usr/bin/env bash\n'; cat; } >"$target"; chmod 0755 "$target"; }
loops=()
cleanup() {
  umount /etc/containers/systemd 2>/dev/null || true; umount /etc/aboutme 2>/dev/null || true; umount /usr/local/lib/aboutme 2>/dev/null || true; umount -R /var/lib/aboutme 2>/dev/null || true
  umount -R /srv/data 2>/dev/null || true
  for device in "${loops[@]}"; do losetup -d "$device"; done
  umount "$work" 2>/dev/null || true
  /usr/bin/rm -rf -- "$work"
}
trap cleanup EXIT
mount --bind "$work" "$work"; mount -o remount,bind,noexec "$work"
stub "$work/exec-probe" <<'STUB'
exit 0
STUB
probe_result=0; "$work/exec-probe" >/dev/null 2>&1 || probe_result=$?
[[ $probe_result == 126 ]] || fail 'noexec fixture control'
mount -o remount,bind,exec "$work"
"$work/exec-probe" >/dev/null 2>&1 || fail 'executable fixture mount'
mkdir -p "$work/bin" "$work/lib" /srv/data /var/lib/aboutme /usr/local/lib/aboutme; truncate -s 64M "$work/disk"
mkfs.ext4 -q -L aboutme-data "$work/disk"; device=$(losetup --find --show "$work/disk")
loops+=("$device"); mount "$device" /srv/data; mkdir /srv/data/aboutme
install -d -o root -g root -m 0700 /srv/data/host-operations
install -o root -g root -m 0600 /dev/null /srv/data/host-operations/.bundle.lock
mount --bind /srv/data/aboutme /var/lib/aboutme
cp "$primitive" "$work/lib/crowdsec-privacy-notice-host.sh"
cp "$root/deploy/vn/scripts/fence.sh" "$root/deploy/vn/scripts/deploy-safety.sh" \
  "$root/deploy/vn/host/workload-lock.sh" "$work/lib/"
for helper in crowdsec-db crowdsec-provision crowdsec-migrate; do
  stub "$work/lib/$helper.sh" <<'STUB'
printf 'crowdsec-called\n' >>"$NOTICE_FIXTURE/crowdsec-effects"
exit 1
STUB
done
mount --bind "$work/lib" /usr/local/lib/aboutme; mkdir -p /run/aboutme; export NOTICE_FIXTURE=$work NOTICE_DEVICE=$device
floor_tag=$(sed -n 's/^floor_tag=//p' /usr/local/lib/aboutme/fence.sh); floor_release=$(sed -n 's/^floor_release=//p' /usr/local/lib/aboutme/fence.sh)
[[ $floor_release =~ ^[0-9]+$ && $floor_tag =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || fail 'installed tracked floor'
above_floor=v${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3] + 1)); above_release=$((floor_release + 1))
for command in sync mv rm; do
  stub "$work/bin/$command" <<'STUB'
set -euo pipefail; name=${0##*/}
printf '%s\n' "$name" >>"$NOTICE_FIXTURE/effects"
if [[ ${NOTICE_INITIAL_FAULT:-none} == "$name:${*: -1}" ]]; then exit 1; fi
if [[ ${NOTICE_INITIAL_RELEASE:-none} != none && $name == mv && ${*: -1} == /var/lib/aboutme/fence.json ]]; then
  replacement=${@: -2:1}
  if jq -e '(.operation_id // null)==null' "$replacement" >/dev/null; then
    case $NOTICE_INITIAL_RELEASE in
      before-store) exit 1 ;;
      after-rename) /usr/bin/mv "$@"; exit 1 ;;
      after-sync | lost-response) touch "$NOTICE_FIXTURE/initial-release-renamed" ;;
    esac
  fi
fi
if [[ $name == sync && ${*: -1} == /var/lib/aboutme && -f $NOTICE_FIXTURE/initial-release-renamed ]]; then
  /usr/bin/sync "$@"
  if [[ $NOTICE_INITIAL_RELEASE == lost-response ]]; then kill -TERM "$PPID"; fi
  exit 1
fi
if [[ $name == mv && ${*: -1} == /usr/local/lib/aboutme/crowdsec-privacy-notice-host.sh ]]; then
  replacement=${@: -2:1}
  [[ $(stat -c '%u:%g:%a:%h' "$replacement") == 0:0:755:1 ]] || exit 1
  [[ $(cat "$NOTICE_FIXTURE/last-file-sync") == "$replacement" ]] || exit 1
fi
case ${*: -1} in
  */privacy-notice) printf '%s directory\n' "$name" >>"$NOTICE_FIXTURE/order" ;;
  */epoch | */send.json | */activation.json | */restore-reconciliation)
    printf '%s %s\n' "$name" "${*: -1}" | sed 's|/var/lib/aboutme/privacy-notice/||' >>"$NOTICE_FIXTURE/order" ;;
  *) printf '%s temporary\n' "$name" >>"$NOTICE_FIXTURE/order" ;;
esac
if [[ $name == sync ]]; then
  n=$(cat "$NOTICE_FIXTURE/sync-count" 2>/dev/null || printf 0); n=$((n + 1))
  printf '%s\n' "$n" >"$NOTICE_FIXTURE/sync-count"
  if [[ ${*: -1} == /var/lib/aboutme/privacy-notice* ]]; then
    [[ -e $NOTICE_FIXTURE/first-authority-sync ]] || printf '%s\n' "$n" >"$NOTICE_FIXTURE/first-authority-sync"; printf '%s\n' "$n" >"$NOTICE_FIXTURE/last-authority-sync"
  fi
  if [[ ${*: -1} == /var/lib/aboutme/privacy-notice ]]; then
    /usr/bin/rm -f "$NOTICE_FIXTURE/await-directory-sync"
  elif [[ -f ${*: -1} && ! -L ${*: -1} ]]; then
    printf '%s\n' "${*: -1}" >"$NOTICE_FIXTURE/last-file-sync"
  fi
fi
if [[ $name == mv && ${*: -1} == /var/lib/aboutme/privacy-notice/* ]]; then
  source_file=${@: -2:1}; [[ $(dirname "$source_file") == /var/lib/aboutme/privacy-notice ]] || exit 1
  [[ $(stat -c '%u:%g:%a:%h' "$source_file") == 0:0:444:1 ]] || exit 1; [[ -f $NOTICE_FIXTURE/last-file-sync && $(cat "$NOTICE_FIXTURE/last-file-sync") == "$source_file" ]] || exit 1
  [[ ! -e $NOTICE_FIXTURE/await-directory-sync ]] || exit 1
  touch "$NOTICE_FIXTURE/await-directory-sync"
fi
if [[ $name == rm && ${NOTICE_CLAIMED:-0} == 1 && $* == *send.json* ]]; then
  [[ -f $NOTICE_FIXTURE/joined ]] || exit 1
fi
exec "/usr/bin/$name" "$@"
STUB
done
stub "$work/bin/systemctl" <<'STUB'
set -euo pipefail
printf '%s\n' "$*" >>"$NOTICE_FIXTURE/systemctl-calls"
case $1 in
  is-active)
    if [[ ${NOTICE_LEGACY_PROTECTION:-inactive} == active ]]; then
      case ${*: -1} in crowdsec* | aboutme-crowdsec-retention*) exit 0 ;; esac
    fi
    [[ ${NOTICE_APP_STATE:-absent} == active || ${*: -1} == aboutme-maintenance* ]] ;;
  show)
    [[ ${NOTICE_APP_STATE:-absent} != inspection-failure ]] || exit 1
    [[ " $* " == *' --all '* ]] || exit 1
    unit_state=${NOTICE_UNIT_STATE:-inactive}; job=${NOTICE_JOB:-}
    if [[ ${NOTICE_LEGACY_PROTECTION:-inactive} == active ]]; then
      case ${*: -1} in crowdsec* | aboutme-crowdsec-retention*) unit_state=active ;; esac
    fi
    [[ ${NOTICE_APP_STATE:-absent} != active ]] || unit_state=active
    if [[ ${*: -1} == postgresql@18-main.service ]]; then unit_state=active; job=${NOTICE_POSTGRES_JOB:-}; [[ ${NOTICE_POSTGRES_INSPECTION:-0} == 0 ]] || exit 1; fi
    if [[ ${NOTICE_CLAIMED:-0} == 1 && -f $NOTICE_FIXTURE/stopped && -z $job && $unit_state == inactive ]]; then
      touch "$NOTICE_FIXTURE/joined"; printf 'join\n' >>"$NOTICE_FIXTURE/order"
    fi
    case $* in
      *MainPID*ControlPID*)
        pid=0; [[ $unit_state != active ]] || pid=1
        printf 'ActiveState=%s\nJob=%s\nMainPID=%s\nControlPID=0\n' "$unit_state" "$job" "$pid" ;;
      *ActiveState*Job*) printf 'ActiveState=%s\nJob=%s\n' "$unit_state" "$job" ;;
      *ActiveState*) printf '%s\n' "$unit_state" ;;
      *Job*) printf '%s\n' "$job" ;;
      *) exit 1 ;;
    esac ;;
  list-jobs)
    [[ ${NOTICE_INITIAL_INSPECTION:-valid} != jobs ]] || exit 1
    if [[ ${NOTICE_LEGACY_PROTECTION:-inactive} == active ]]; then
      printf '1 aboutme-crowdsec-retention.service start running\n'
    fi
    [[ -z ${NOTICE_INITIAL_JOB:-} ]] || printf '2 %s start waiting\n' "$NOTICE_INITIAL_JOB"
    ;;
  list-units)
    [[ ${NOTICE_INITIAL_INSPECTION:-valid} != units ]] || exit 1
    if [[ ${NOTICE_INITIAL_SLICE:-absent} == active ]]; then
      printf '%s\n' 'system-aboutme\x2djob.slice loaded active active Slice /system/aboutme-job'
    fi
    if [[ ${NOTICE_LEGACY_PROTECTION:-inactive} == active ]]; then
      printf '%s\n' 'crowdsec.service loaded active running protection' \
        'crowdsec-firewall-bouncer.service loaded active running bouncer' \
        'aboutme-crowdsec-retention.timer loaded active waiting retention' \
        'aboutme-crowdsec-retention-startup.service loaded active exited retention'
    fi
    if [[ -n ${NOTICE_INITIAL_UNIT:-} ]]; then
      if [[ ${NOTICE_INITIAL_MASKED:-0} == 1 ]]; then
        [[ " $* " == *' --plain '* ]] || printf '● '
        printf '%s masked active running Restore\n' "$NOTICE_INITIAL_UNIT"
      else
        printf '%s loaded active running writer\n' "$NOTICE_INITIAL_UNIT"
      fi
    fi
    ;;
  stop)
    if [[ ${NOTICE_CAPTURE:-0} == 1 && $* == *aboutme-server* ]]; then
      [[ -f /var/lib/aboutme/privacy-notice/capture-in-progress ]] || exit 1
    fi
    printf 'stop\n' >>"$NOTICE_FIXTURE/order"
    if [[ $* == *aboutme-server* ]]; then touch "$NOTICE_FIXTURE/stopped"; fi
    ;;
  start) printf 'start\n' >>"$NOTICE_FIXTURE/order" ;;
  *) exit 1 ;;
esac
STUB
stub "$work/bin/pgrep" <<'STUB'
[[ ${NOTICE_APP_STATE:-absent} != process ]] || exit 0; exit 1
STUB
stub "$work/bin/flock" <<'STUB'
set -euo pipefail; [[ ${NOTICE_LOCK:-valid} != contention ]] || exit 1
if [[ ${NOTICE_LOCK:-valid} == changed && ! -e $NOTICE_FIXTURE/changed ]]; then
  touch "$NOTICE_FIXTURE/changed"; mount --bind /srv/data/other /var/lib/aboutme
fi
exec /usr/bin/flock "$@"
STUB
stub "$work/bin/blkid" <<'STUB'
case ${NOTICE_LABEL:-valid} in
  absent) exit 2 ;;
  duplicate) printf '%s\n%s\n' "$NOTICE_DEVICE" "$NOTICE_DEVICE" ;;
  failure) exit 1 ;;
  *) exec /usr/sbin/blkid "$@" ;;
esac
STUB
for command in podman psql pgbackrest; do
  stub "$work/bin/$command" <<'STUB'
printf 'forbidden\n' >>"$NOTICE_FIXTURE/forbidden"; exit 1
STUB
done
chmod 0755 "$work/bin/"* "$work/lib/"*; export PATH=$work/bin:$PATH
host=/usr/local/lib/aboutme/crowdsec-privacy-notice-host.sh; fence=/usr/local/lib/aboutme/fence.sh
authority=/var/lib/aboutme/privacy-notice
notice_test_ms() {
  local stamp
  read -r stamp _ </proc/uptime
  stamp=${stamp/./}
  printf '%d\n' "$((10#$stamp * 10))"
}
release_notice_child() {
  python3 -I - "$1" "$2" <<'PYTHON'
import os, select, sys, time
try:
    pid = int(sys.argv[1]); children = [os.pidfd_open(pid)]
    while pid > 1:
        try:
            with open(f'/proc/{pid}/status') as status:
                pid = next(int(line.split()[1]) for line in status if line.startswith('PPid:'))
            descriptors = os.listdir(f'/proc/{pid}/fd')
        except FileNotFoundError:
            break
        for fd in descriptors:
            try:
                if os.readlink(f'/proc/{pid}/fd/{fd}') == '/run/aboutme/workload.lock':
                    children.append(os.pidfd_open(pid)); break
            except (FileNotFoundError, ProcessLookupError):
                continue
    with open(sys.argv[2], 'w') as latch:
        latch.write('continue\n')
    deadline = time.monotonic() + 30
    while children:
        ready, _, _ = select.select(children, [], [], max(0, deadline - time.monotonic()))
        if not ready:
            sys.exit(1)
        for child in ready:
            children.remove(child); os.close(child)
except OSError:
    sys.exit(1)
PYTHON
}
refusal_count=0
refusal_details() {
  local category=other
  if grep -Fq 'Text file busy' "$work/err"; then category=text-file-busy
  elif grep -Fq 'Permission denied' "$work/err"; then category=permission-denied
  fi
  printf 'refusal=%d caller_lines=(%s) exit=%d elapsed_ms=%d stdout_bytes=%d stderr_bytes=%d stderr_category=%s' \
    "$refusal_count" "$3" "$1" "$2" "$(wc -c <"$work/out")" "$(wc -c <"$work/err")" "$category"
}
refuse() {
  local result=0 started elapsed
  refusal_count=$((refusal_count + 1)); started=$(notice_test_ms)
  "$@" >"$work/out" 2>"$work/err" || result=$?
  elapsed=$(( $(notice_test_ms) - started ))
  [[ $result == 1 && ! -s $work/out ]] || fail "refusal exit or stdout $(refusal_details "$result" "$elapsed" "${BASH_LINENO[*]}")"; printf 'invalid_state\n' >"$work/expected"
  cmp -s "$work/expected" "$work/err" || fail "refusal stderr $(refusal_details "$result" "$elapsed" "${BASH_LINENO[*]}")"
}
quiet() {
  "$@" >"$work/out" 2>"$work/err" || fail 'denial operation refused'
  [[ ! -s $work/out && ! -s $work/err ]] || fail 'success output'
}
reset_owner() { cp "$work/adopted-fence" /var/lib/aboutme/fence.json; }
for action in unknown --force --resume authorize-send reconcile-initial pre-restore postcheck finish; do refuse "$host" "$action"; done
refuse "$host" initialize extra; refuse "$host" pre-restore extra
for action in pre-restore postcheck finish resume-owned-operation; do
  refuse bash "$wrapper" "$action"
done
for label in absent duplicate failure; do
  NOTICE_LABEL=$label refuse "$host" initialize; [[ ! -e /var/lib/aboutme/fence.json && ! -e $authority ]] || fail 'label failure touched state'
done
umount /var/lib/aboutme; umount /srv/data; refuse "$host" initialize; mount "$device" /srv/data
mount --bind /srv/data/aboutme /var/lib/aboutme
umount /var/lib/aboutme; refuse "$host" initialize; [[ ! -e /var/lib/aboutme/fence.json ]] || fail 'root shadow initialized'
mount --bind /srv/data/aboutme /var/lib/aboutme; mkdir /srv/data/other; mount --bind /srv/data/other /var/lib/aboutme; refuse "$host" initialize
[[ ! -e /srv/data/other/fence.json ]] || fail 'wrong bind initialized'; umount /var/lib/aboutme; mount -t tmpfs tmpfs /srv/data
refuse "$host" initialize; umount /srv/data; mount --bind /srv/data/aboutme /var/lib/aboutme; refuse "$host" initialize
umount /var/lib/aboutme; NOTICE_LOCK=changed refuse "$host" initialize; [[ ! -e /srv/data/other/fence.json ]] || fail 'identity change initialized'
umount /var/lib/aboutme; NOTICE_LOCK=contention refuse "$host" initialize; quiet "$host" initialize
[[ $(jq -r '.operation_kind // "none"' /var/lib/aboutme/fence.json) == none ]] || fail 'successful bootstrap retained operation'
[[ $(stat -c '%u:%g:%a' "$authority") == 0:0:755 ]] || fail 'directory metadata'
for name in epoch initial-epoch restore-reconciliation; do [[ $(stat -c '%u:%g:%a:%h' "$authority/$name") == 0:0:444:1 ]] || fail 'file metadata'; done
cmp -s "$authority/epoch" "$authority/initial-epoch" || fail 'bootstrap anchor mismatch'
[[ ! -s $authority/restore-reconciliation ]] || fail 'marker contents'; [[ $(wc -c <"$authority/epoch") == 37 ]] || fail 'epoch length'
grep -qxE '[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}' "$authority/epoch" || fail 'epoch grammar'
jq -e '.notice_authority | keys==["operation_id","state","version"] and .version==1 and .state=="adopted" and (.operation_id|test("^[A-Za-z0-9_-]{43}$"))' \
  /var/lib/aboutme/fence.json >/dev/null || fail 'permanent evidence'
cp "$authority/epoch" "$work/initial-epoch"; cp /var/lib/aboutme/fence.json "$work/adopted-fence"; quiet "$host" initialize
cmp -s "$authority/epoch" "$work/initial-epoch" || fail 'reinstall rotated epoch'; [[ ! -e /var/lib/aboutme/release.json ]] || fail 'bootstrap synthesized release'
rm "$authority/initial-epoch"; refuse "$host" initialize
[[ ! -e $authority/initial-epoch ]] || fail 'adopted reinstall recreated anchor'
cp "$work/initial-epoch" "$authority/initial-epoch"; chmod 0444 "$authority/initial-epoch"
[[ ! -e $authority/send.json && ! -e $authority/activation.json ]] || fail 'bootstrap issued receipt'
for command in prepare enqueue status activate authorize-send reconcile-initial; do refuse bash "$wrapper" "$command" extra; done
refuse bash "$wrapper" --force; refuse bash "$wrapper" --resume
/usr/bin/rm -f "$work/await-directory-sync"; cp "$authority/epoch" "$work/saved-epoch"; rm "$authority/epoch"
refuse "$host" initialize; [[ ! -e $authority/epoch ]] || fail 'lost adopted state reinitialized'
cp "$work/saved-epoch" "$authority/epoch"; chmod 0444 "$authority/epoch"
jq 'del(.notice_authority)' "$work/adopted-fence" > /var/lib/aboutme/fence.json
refuse "$host" initialize; reset_owner
for state in 'null' '{}' '{"version":2,"state":"adopted"}' '{"version":1,"state":"other"}'; do
  jq --argjson state "$state" '.notice_authority=$state' "$work/adopted-fence" > /var/lib/aboutme/fence.json
  refuse "$host" initialize
done
reset_owner; initializing_id=$(jq -r .notice_authority.operation_id "$work/adopted-fence")
jq '.notice_authority.state="initializing" | .operation_id=("B"*43) | .operation_kind="notice_restore"
  | .operation_started_at="2026-10-19T00:00:00Z" | .operation_checked_at=.operation_started_at' \
  "$work/adopted-fence" > /var/lib/aboutme/fence.json
refuse "$host" initialize
jq --arg id "$initializing_id" '.operation_id=$id' /var/lib/aboutme/fence.json >"$work/resume-fence"
cp "$work/resume-fence" /var/lib/aboutme/fence.json; rm "$authority/initial-epoch"; quiet "$host" initialize
cmp -s "$authority/initial-epoch" "$authority/epoch" || fail 'resumed bootstrap anchor mismatch'
jq -e --arg id "$initializing_id" '.notice_authority.state=="adopted" and .notice_authority.operation_id==$id' \
  /var/lib/aboutme/fence.json >/dev/null || fail 'initialization changed recorded owner'
cp /var/lib/aboutme/fence.json "$work/adopted-fence"
reset_owner; refuse "$host" adopt extra; refuse "$host" adopt --force; refuse "$host" adopt
[[ ! -e $work/forbidden ]] || fail 'host primitive called application dependency'
mkdir "$work/legacy" "$work/reviewed"
for name in fence deploy-host deploy-safety; do
  cp "$root/deploy/vn/tests/fixtures/legacy-notice-adoption/$name.sh.txt" "$work/legacy/$name.sh"
  cp "$root/deploy/vn/scripts/$name.sh" "$work/reviewed/$name.sh"
done
cp "$root/deploy/vn/scripts/image-prune.sh" "$work/reviewed/"
cp "$root/deploy/vn/host/workload-lock.sh" "$work/reviewed/"; chmod 0755 "$work/legacy/"*.sh "$work/reviewed/"*.sh; legacy_tag=v0.7.9
legacy_server=ghcr.io/dannyota/aboutme-server@sha256:$(printf '%064d' 1); legacy_web=ghcr.io/dannyota/aboutme-web@sha256:$(printf '%064d' 2)
jq -n --arg server "$legacy_server" --arg web "$legacy_web" \
  '{release_tag:"v0.7.9",release_number:7009,maintenance_tag:"v0.7.9",maintenance_number:7009,
    server_image:$server,web_image:$web,caddy_image:("ghcr.io/dannyota/aboutme-caddy@sha256:"+("0"*64)),
    maintenance_image:("ghcr.io/dannyota/aboutme-caddy@sha256:"+("0"*64))}' >"$work/legacy/release.json"
legacy_values=("$legacy_tag" "$(sha256sum "$work/legacy/release.json" | cut -d' ' -f1)"
  "$legacy_server" "$legacy_web"
  "$(sha256sum "$work/legacy/fence.sh" | cut -d' ' -f1)"
  "$(sha256sum "$work/legacy/deploy-host.sh" | cut -d' ' -f1)"
  "$(sha256sum "$work/legacy/deploy-safety.sh" | cut -d' ' -f1)")
cp "$primitive" "$work/reviewed/crowdsec-privacy-notice-host.sh"
for index in "${!legacy_fields[@]}"; do sed -i "s|^readonly ${legacy_fields[$index]}='[^']*'$|readonly ${legacy_fields[$index]}='${legacy_values[$index]}'|" "$work/reviewed/crowdsec-privacy-notice-host.sh"; done
adopt=$work/reviewed/crowdsec-privacy-notice-host.sh
for command in cp install; do
  stub "$work/bin/$command" <<'STUB'
set -euo pipefail
if [[ ${NOTICE_ADOPTION:-0} == 1 ]]; then
  case ${*: -1} in
    /usr/local/lib/aboutme/fence.sh | /usr/local/lib/aboutme/deploy-host.sh | /usr/local/lib/aboutme/deploy-safety.sh | /usr/local/lib/aboutme/image-prune.sh)
      if [[ ${*: -1} == /usr/local/lib/aboutme/deploy-host.sh ]]; then
        cmp -s "$NOTICE_FIXTURE/reviewed/image-prune.sh" /usr/local/lib/aboutme/image-prune.sh || {
          printf 'deploy-host installed before image-prune matched\n' >>"$NOTICE_FIXTURE/violations"
          exit 1
        }
      fi
      cmp -s "$NOTICE_FIXTURE/reviewed/crowdsec-privacy-notice-host.sh" /usr/local/lib/aboutme/crowdsec-privacy-notice-host.sh || exit 1
      jq -e '.notice_authority.state=="initializing" and .operation_kind=="cutover" and .notice_authority.operation_id==.operation_id' /var/lib/aboutme/fence.json >/dev/null || exit 1
      jq -e '.mutation_kind=="quiesce" and .state=="active"' /var/lib/aboutme/cutover-mutation.json >/dev/null || exit 1
      printf 'helper-replaced\n' >>"$NOTICE_FIXTURE/order"
      [[ ${NOTICE_ADOPT_STOP:-none} != "before:${*: -1}" ]] || exit 1
      [[ ${NOTICE_ADOPT_STOP:-none} != "skip:${*: -1}" ]] || exit 0
      if [[ ${NOTICE_ADOPT_STOP:-none} == "after:${*: -1}" ]]; then "/usr/bin/${0##*/}" "$@"; exit 1; fi
      [[ ${NOTICE_ADOPT_STOP:-none} != "missing:${*: -1}" ]] || { /usr/bin/rm -f -- "${*: -1}"; exit 1; }
      if [[ ${NOTICE_ADOPT_STOP:-none} == "mode600:${*: -1}" || ${NOTICE_ADOPT_STOP:-none} == "partial:${*: -1}" ]]; then /usr/bin/install -o root -g root -m 0600 "${@: -2}"; [[ $NOTICE_ADOPT_STOP != "partial:${*: -1}" ]] || printf 'incomplete\n' >"${*: -1}"; exit 1; fi
      ;;
  esac
fi
exec "/usr/bin/${0##*/}" "$@"
STUB
done
rm -rf -- "$authority"; rm -f /var/lib/aboutme/fence.json /var/lib/aboutme/fence.lock "$host"; cp "$work/legacy/"*.sh "$work/lib/"; cp "$work/legacy/release.json" /var/lib/aboutme/release.json
"$fence" init >"$work/out" 2>"$work/err"
for fault in unknown-helper unknown-release; do
  if [[ $fault == unknown-helper ]]; then
    printf '\n# synthetic mismatch\n' >>"$work/lib/deploy-host.sh"
  else
    jq '.release_tag="v0.7.10" | .release_number=7010' "$work/legacy/release.json" > /var/lib/aboutme/release.json
  fi
  refuse bash "$adopt" adopt; [[ ! -e $authority ]] || fail 'ineligible adoption touched authority'
  cp "$work/legacy/"*.sh "$work/lib/"; cp "$work/legacy/release.json" /var/lib/aboutme/release.json
done
for fault in mv:/usr/local/lib/aboutme/crowdsec-privacy-notice-host.sh sync:/usr/local/lib/aboutme; do
  NOTICE_ADOPTION=1 NOTICE_INITIAL_FAULT=$fault refuse bash "$adopt" adopt
  jq -e '.notice_authority.state=="initializing" and .operation_kind=="cutover"' /var/lib/aboutme/fence.json >/dev/null || fail 'helper persistence failure lost adoption'
  for name in fence deploy-host deploy-safety; do
    cmp -s "$work/legacy/$name.sh" "$work/lib/$name.sh" || fail 'guard replaced before helper persistence'
  done
  [[ ! -e $work/lib/image-prune.sh ]] || fail 'image-prune installed before helper persistence'
  NOTICE_ADOPTION=1 quiet bash "$adopt" adopt
  rm -rf -- "$authority"; rm -f /var/lib/aboutme/fence.json /var/lib/aboutme/cutover-mutation.json "$host" "$work/lib/image-prune.sh"
  cp "$work/legacy/"*.sh "$work/lib/"; "$fence" init >"$work/out" 2>"$work/err"
done
touch /run/aboutme/crowdsec-retention-failed
NOTICE_ADOPTION=1 quiet bash "$adopt" adopt; [[ -f $authority/restore-reconciliation && -f $authority/epoch ]] || fail 'eligible adoption did not establish denial'
[[ -e /run/aboutme/crowdsec-retention-failed ]] || fail 'legacy adoption cleared modern retention failure'
rm /run/aboutme/crowdsec-retention-failed
cmp -s "$authority/epoch" "$authority/initial-epoch" || fail 'adoption anchor mismatch'
cmp -s "$adopt" "$host" || fail 'adoption canonical helper mismatch'
jq -e '.notice_authority.state=="adopted" and .minimum_release==4007' /var/lib/aboutme/fence.json >/dev/null || fail 'adoption evidence or floor'
refuse bash "$adopt" adopt
for boundary in before:fence.sh after:fence.sh after:deploy-host.sh after:deploy-safety.sh after:image-prune.sh \
  skip:deploy-host.sh skip:image-prune.sh {missing,mode600,partial}:{fence,deploy-host,deploy-safety,image-prune}.sh; do
  rm -rf -- "$authority"; rm -f /var/lib/aboutme/fence.json /var/lib/aboutme/cutover-mutation.json
  rm -f "$host" "$work/lib/image-prune.sh"
  cp "$work/legacy/"*.sh "$work/lib/"; "$fence" init >"$work/out" 2>"$work/err"
  NOTICE_ADOPTION=1 NOTICE_ADOPT_STOP=${boundary/:/:\/usr\/local\/lib\/aboutme\/} refuse bash "$adopt" adopt
  if [[ $boundary == *:image-prune.sh ]]; then
    cmp -s "$work/legacy/deploy-host.sh" "$work/lib/deploy-host.sh" || fail 'deploy-host replaced before image-prune was verified'
  fi
  adoption_owner=$(jq -er '.notice_authority.operation_id' /var/lib/aboutme/fence.json)
  jq -e --arg id "$adoption_owner" '.notice_authority.state=="initializing" and .operation_kind=="cutover" and .operation_id==$id' /var/lib/aboutme/fence.json >/dev/null || fail 'interrupted adoption lost owner'
  NOTICE_ADOPTION=1 NOTICE_APP_STATE=inspection-failure refuse bash "$adopt" adopt
  jq -e --arg id "$adoption_owner" '.notice_authority.state=="initializing" and .operation_id==$id' /var/lib/aboutme/fence.json >/dev/null || fail 'unproved quiescence completed adoption'
  NOTICE_ADOPTION=1 quiet bash "$adopt" adopt
  jq -e --arg id "$adoption_owner" '.notice_authority.state=="adopted" and .notice_authority.operation_id==$id and .minimum_release==4007 and (.operation_id // null)==null' /var/lib/aboutme/fence.json >/dev/null || fail 'resumed adoption changed owner or floor'
  [[ ! -e /var/lib/aboutme/cutover-mutation.json && -f $authority/restore-reconciliation ]] || fail 'resumed adoption did not settle denial'
  for name in fence deploy-host deploy-safety image-prune; do cmp -s "$work/reviewed/$name.sh" "$work/lib/$name.sh" || fail 'resumed adoption retained old helper'; done
done
[[ ! -s $work/violations ]] || fail "$(cat "$work/violations")"
for field in "${legacy_fields[@]}"; do export "$field=caller_override"; done
refuse bash "$adopt" adopt
for field in "${legacy_fields[@]}"; do unset "$field"; done
cp "$root/deploy/vn/scripts/fence.sh" "$root/deploy/vn/scripts/deploy-safety.sh" "$work/lib/"; mkdir -p "$work/units" "$work/etc" /etc/containers/systemd /etc/aboutme
mount --bind "$work/units" /etc/containers/systemd; mount --bind "$work/etc" /etc/aboutme; : >"$work/etc/server.env"
: >"$work/etc/flags.env"
release_fixture() {
  jq --arg tag "$1" --argjson number "$2" '.release_tag=$tag | .release_number=$number' "$work/legacy/release.json" > /var/lib/aboutme/release.json
  sed -e "s/@RELEASE_TAG@/$1/g" -e "s/@RELEASE_NUMBER@/$2/g" \
    -e "s|@SERVER_IMAGE@|$legacy_server|g" -e "s|@WEB_IMAGE@|$legacy_web|g" \
    -e '/@SERVER_SECRETS@/d' "$root/deploy/vn/host/quadlet/aboutme-server.container.in" >"$work/units/aboutme-server.container"
}
release_fixture "$floor_tag" "$floor_release"
printf '[Container]\nImage=%s\n' "$legacy_web" >"$work/units/aboutme-web.container"
stub "$work/bin/podman" <<'STUB'
set -euo pipefail
if [[ $1 == secret && $2 == exists && $# == 3 ]]; then exit 0; fi
[[ $1 == run ]] || exit 1; printf '%s\n' "$@" >"$NOTICE_FIXTURE/container-args"
[[ $* == *'--network=none'* && $* == *'--memory=256m'* ]] || exit 1
case $* in
  *SMTP* | *MEDIA* | *smtp.env* | *--privileged* | *--network=host*) exit 1 ;;
esac
[[ $* == *'privacy-notice:/var/lib/aboutme/privacy-notice:ro'* ]] || exit 1; [[ $* == *'server crowdsec-privacy-notice '* ]] || exit 1
if [[ ${*: -1} == reconcile-initial ]]; then
  /usr/bin/flock -n /run/aboutme/workload.lock true && exit 1
  jq -e '.operation_kind=="cutover"' /var/lib/aboutme/fence.json >/dev/null || exit 1
  jq -e '.mutation_kind=="quiesce"' /var/lib/aboutme/cutover-mutation.json >/dev/null || exit 1
  printf 'initial-call\n' >>"$NOTICE_FIXTURE/initial-calls"
  case ${NOTICE_INITIAL_DRIFT:-none} in
    epoch) printf '00000000-0000-4000-8000-000000000000\n' > /var/lib/aboutme/privacy-notice/epoch ;;
    release) jq '.release_number=1' /var/lib/aboutme/release.json >"$NOTICE_FIXTURE/drift-release"; /usr/bin/cp "$NOTICE_FIXTURE/drift-release" /var/lib/aboutme/release.json ;;
    owner) jq '.operation_id=("B"*43)' /var/lib/aboutme/fence.json >"$NOTICE_FIXTURE/drift-owner"; /usr/bin/cp "$NOTICE_FIXTURE/drift-owner" /var/lib/aboutme/fence.json ;;
    mount) mount --bind /srv/data/other /var/lib/aboutme; touch "$NOTICE_FIXTURE/initial-mount-drift" ;;
    signal) kill -TERM "$PPID"; exit 1 ;;
  esac
  if [[ ${NOTICE_INITIAL_HOLD:-none} == foreground ]]; then
    printf '%s\n' "$BASHPID" >"$NOTICE_FIXTURE/initial-held-child"
    printf 'ready\n' >"$NOTICE_FIXTURE/initial-ready"
    read -r -t 30 _ <"$NOTICE_FIXTURE/initial-continue" || exit 1
  elif [[ ${NOTICE_INITIAL_HOLD:-none} == descendant ]]; then
    (exec >/dev/null 2>&1; printf '%s\n' "$BASHPID" >"$NOTICE_FIXTURE/initial-held-child"
      read -r -t 10 _ <"$NOTICE_FIXTURE/initial-continue") &
  fi
fi
if [[ $* != *' crowdsec-privacy-notice enqueue'* ]]; then
  case $* in *auth-email-active-key* | *auth-email-previous-key*) exit 1 ;; esac
fi
[[ ${NOTICE_APP_STDERR:-0} == 0 ]] || printf 'fixture_failure\n' >&2
[[ ${NOTICE_APP_ERROR:-0} == 0 ]] || { printf 'fixture_failure\n' >&2; exit 1; }; cat "$NOTICE_FIXTURE/aggregate"
exit "$(cat "$NOTICE_FIXTURE/app-exit")"
STUB
stub "$work/bin/date" <<'STUB'
case " $* " in
  *' -d '* | *' --date='*) exec /usr/bin/date "$@" ;;
  *) exec /usr/bin/date --date=2026-11-01T00:00:00Z "$@" ;;
esac
STUB
digest=bb128b39501f09db59915f3f75759572a49349ec78fe17ad48b6ba40d500ffdc
literal() { sed -nE "s/^(const )?[[:space:]]*$1[[:space:]]*=[[:space:]]*\"([^\"]*)\"$/\\2/p" "$2"; }
manifest_source=$root/apps/server/internal/privacynotice/manifest.go; copy_source=$root/apps/server/internal/authmail/privacy_notice_copy.go
{
  printf '%s\n' aboutme-crowdsec-privacy-content-v1 campaign_id=crowdsec-postgres-paths-v1; printf 'publication_date=%s\n' "$(literal PublicationDate "$manifest_source")"
  printf 'canonical_link=%s\n' "$(literal PrivacyNoticeURL "$copy_source")"; printf 'public_en=%s\n' "$(literal publicEN "$manifest_source")"
  printf 'public_vi=%s\n' "$(literal publicVI "$manifest_source")"
  for pair in email_subject:PrivacyNoticeSubject email_button:PrivacyNoticeAction \
    email_heading_vi:PrivacyNoticeHeadingVI email_heading_en:PrivacyNoticeHeadingEN \
    email_preheader:PrivacyNoticePreheader email_body_vi:PrivacyNoticeBodyVI email_body_en:PrivacyNoticeBodyEN; do
    printf '%s=%s\n' "${pair%%:*}" "$(literal "${pair#*:}" "$copy_source")"
  done
} >"$work/manifest"; [[ $(wc -c <"$work/manifest") == 4683 && $(wc -l <"$work/manifest") == 13 ]] || fail 'manifest bytes'
[[ $(sha256sum "$work/manifest" | cut -d' ' -f1) == "$digest" ]] || fail 'independent manifest digest'
jq -n --arg digest "$digest" '{schema_version:1,result:"pending",campaign_id:"crowdsec-postgres-paths-v1",
  content_sha256:$digest,cutoff_at:"2026-10-19T01:02:03.000000Z",expected_count:1,state:"sealed",actual_count:1,
  counts:{unqueued:1,queued:0,accepted:0,deleted:0,failed:0,cancelled:0},
  failure_counts:{expired:0,attempts_exhausted:0,provider_rejected:0,payload_invalid:0,job_missing:0,delivery_failed:0},
  recovery_count:0,recovery_counts:{expired:0,attempts_exhausted:0,provider_rejected:0,payload_invalid:0,job_missing:0,delivery_failed:0},
  activation_count:0,sealed_at:"2026-10-19T01:02:04.000000Z",first_activated_at:null,activated_at:null,
  aborted_at:null,last_accepted_at:null}' >"$work/sealed"
cp "$work/sealed" "$work/aggregate"; printf '2\n' >"$work/app-exit"
app() {
  local expected=$1 result=0; shift
  bash "$wrapper" "$@" >"$work/out" 2>"$work/err" || result=$?; [[ $result == "$expected" && ! -s $work/err ]] || fail 'owner command result'
  if [[ $1 == authorize-send ]]; then
    [[ ! -s $work/out ]] || fail 'host authorization exposed output'
  else
    [[ $(wc -c <"$work/out") -le 4096 && $(tail -c 1 "$work/out") == '' ]] || fail 'aggregate output framing'
    [[ $(jq -Sc . "$work/out") == "$(jq -Sc . "$work/aggregate")" ]] || fail 'aggregate output changed'
  fi; cp /var/lib/aboutme/fence.json "$work/owner-baseline"
}
invalid_aggregate() { refuse bash "$wrapper" "${1:-authorize-send}"; jq -e '.operation_kind=="deploy" and (.operation_id|type=="string")' /var/lib/aboutme/fence.json >/dev/null || fail 'invalid post-call output released owner'; cp "$work/owner-baseline" /var/lib/aboutme/fence.json; }
"$fence" check "$floor_release" aboutme-server >"$work/out" 2>"$work/err" || fail 'notice marker blocked compatible ordinary mail'
refuse bash "$wrapper" enqueue; refuse bash "$wrapper" authorize-send
jq -nc --arg digest "$digest" '{schema_version:1,result:"initial_reconciled",campaign_id:"crowdsec-postgres-paths-v1",
  content_sha256:$digest,campaign_count:0,recipient_count:0,notice_job_count:0}' >"$work/initial"
cp /var/lib/aboutme/fence.json "$work/initial-fence"; cp "$authority/epoch" "$work/initial-current"
cp /var/lib/aboutme/release.json "$work/initial-release"
initial_reset() {
  cp "$work/initial-fence" /var/lib/aboutme/fence.json; rm -f /var/lib/aboutme/cutover-mutation.json "$work/initial-release-renamed"
  cp "$work/initial-current" "$authority/epoch"; cp "$work/initial-release" /var/lib/aboutme/release.json
  cp "$work/initial" "$work/aggregate"; printf '0\n' >"$work/app-exit"
}
initial_refuse() {
  refuse bash "$wrapper" reconcile-initial
  if [[ -f $work/initial-mount-drift ]]; then umount /var/lib/aboutme; rm "$work/initial-mount-drift"; fi
  jq -e '.operation_kind=="cutover"' /var/lib/aboutme/fence.json >/dev/null || fail 'initial failure released owner'
  [[ -f /var/lib/aboutme/cutover-mutation.json ]] || fail 'initial failure cleared quiesce'
  [[ ! -e $authority/send.json && ! -e $authority/activation.json ]] || fail 'initial failure issued authority'
  initial_reset
}
initial_reset
for mutation in '.extra=true' '.schema_version=true' '.campaign_count=1' '.recipient_count=-1' '.notice_job_count="0"' \
  '.result="sealed"' '.content_sha256=("0"*64)' 'del(.recipient_count)'; do
  jq -c "$mutation" "$work/initial" >"$work/aggregate"; initial_refuse
done
for raw in '{}' '{} {}' '{"schema_version":1,"schema_version":1}' '{bad}'; do
  printf '%s\n' "$raw" >"$work/aggregate"; initial_refuse
done
tr -d '\n' <"$work/initial" >"$work/aggregate"; initial_refuse
cp "$work/initial" "$work/aggregate"; printf '\n' >>"$work/aggregate"; initial_refuse
head -c 4097 /dev/zero >"$work/aggregate"; initial_refuse
for result in 1 2; do printf '%s\n' "$result" >"$work/app-exit"; initial_refuse; done
NOTICE_APP_ERROR=1 initial_refuse
NOTICE_APP_STDERR=1 initial_refuse
for drift in epoch release owner mount signal; do NOTICE_INITIAL_DRIFT=$drift initial_refuse; done
before=$(wc -l <"$work/initial-calls")
for object in missing symlink hardlink fifo writable malformed mismatch; do
  rm -f "$authority/initial-epoch"
  case $object in
    missing) : ;;
    symlink) ln -s "$authority/epoch" "$authority/initial-epoch" ;;
    hardlink) ln "$authority/epoch" "$authority/initial-epoch" ;;
    fifo) mkfifo "$authority/initial-epoch" ;;
    writable) cp "$work/initial-current" "$authority/initial-epoch"; chmod 0666 "$authority/initial-epoch" ;;
    malformed) printf 'invalid\n' >"$authority/initial-epoch"; chmod 0444 "$authority/initial-epoch" ;;
    mismatch) printf '00000000-0000-4000-8000-000000000000\n' >"$authority/initial-epoch"; chmod 0444 "$authority/initial-epoch" ;;
  esac
  refuse bash "$wrapper" reconcile-initial
  [[ $(wc -l <"$work/initial-calls") == "$before" ]] || fail 'invalid anchor reached database'
done
rm -f "$authority/initial-epoch"; cp "$work/initial-current" "$authority/initial-epoch"; chmod 0444 "$authority/initial-epoch"
for name in send.json activation.json capture-in-progress; do
  touch "$authority/$name"; chmod 0444 "$authority/$name"; refuse bash "$wrapper" reconcile-initial
  rm "$authority/$name"
done
NOTICE_APP_STATE=inspection-failure refuse bash "$wrapper" reconcile-initial; initial_reset
NOTICE_JOB=1 refuse bash "$wrapper" reconcile-initial; initial_reset
before=$(wc -l <"$work/initial-calls")
for unit in aboutme-migrate.service aboutme-db-setup.service aboutme-job@privacy-retention-sweep.service \
  'aboutme-job@privacy\x2dretention\x2dsweep.service' 'aboutme-job-privacy\x2dretention\x2dsweep.timer' \
  aboutme-restore.service 'aboutme-restore\x2ddrill.service' postgresql-recovery.service; do
  NOTICE_INITIAL_SLICE=active NOTICE_INITIAL_JOB=$unit refuse bash "$wrapper" reconcile-initial; initial_reset
  NOTICE_INITIAL_SLICE=active NOTICE_INITIAL_UNIT=$unit refuse bash "$wrapper" reconcile-initial; initial_reset
done
NOTICE_INITIAL_SLICE=active NOTICE_INITIAL_MASKED=1 NOTICE_INITIAL_UNIT=aboutme-restore.service refuse bash "$wrapper" reconcile-initial; initial_reset
for inspection in jobs units; do NOTICE_INITIAL_SLICE=active NOTICE_INITIAL_INSPECTION=$inspection refuse bash "$wrapper" reconcile-initial; initial_reset; done
[[ $(wc -l <"$work/initial-calls") == "$before" ]] || fail 'nonquiescent writer reached initial database proof'
for fault in rm:/var/lib/aboutme/privacy-notice/restore-reconciliation sync:/var/lib/aboutme/privacy-notice; do
  NOTICE_INITIAL_FAULT=$fault initial_refuse
done
mkfifo "$work/initial-continue"; exec {initial_continue_fd}<>"$work/initial-continue"
NOTICE_INITIAL_HOLD=descendant initial_refuse
rm -f "$work/initial-held-child"
mkfifo "$work/initial-ready"; exec {initial_ready_fd}<>"$work/initial-ready"
initial_started=$(notice_test_ms)
(
  NOTICE_INITIAL_HOLD=foreground bash "$wrapper" reconcile-initial >"$work/initial-death-out" 2>"$work/initial-death-err" &
  initial_pid=$!; printf '%s\n' "$initial_pid" >"$work/initial-parent"
  initial_result=0; wait "$initial_pid" 2>/dev/null || initial_result=$?
  printf '%s\n' "$initial_result" >"$work/initial-exit"
  printf 'exited\n' >"$work/initial-ready"
) &
initial_fixture_pid=$!; initial_state=
if ! read -r -t 30 initial_state <&"$initial_ready_fd" || [[ $initial_state != ready ]]; then
  initial_elapsed=$(( $(notice_test_ms) - initial_started )); initial_running=1; initial_result=-1
  if [[ $initial_state == exited ]]; then
    initial_running=0; initial_result=$(cat "$work/initial-exit")
  fi
  printf -v initial_message 'initial child never reached latch state=%s elapsed_ms=%d running=%d exit=%d stdout_bytes=%d stderr_bytes=%d' \
    "${initial_state:-timeout}" "$initial_elapsed" "$initial_running" "$initial_result" "$(wc -c <"$work/initial-death-out")" "$(wc -c <"$work/initial-death-err")"
  fail "$initial_message"
fi
initial_pid=$(cat "$work/initial-parent")
kill -KILL "$initial_pid"
if ! read -r -t 30 initial_state <&"$initial_ready_fd" || [[ $initial_state != exited ]]; then fail 'initial fixture left child alive'; fi
wait "$initial_fixture_pid" 2>/dev/null || true; exec {initial_ready_fd}>&-
/usr/bin/flock -n /run/aboutme/workload.lock true && fail 'initial parent death lost inherited lock'
jq -e '.operation_kind=="cutover"' /var/lib/aboutme/fence.json >/dev/null || fail 'initial parent death lost owner'
release_notice_child "$(cat "$work/initial-held-child")" "$work/initial-continue" || fail 'initial fixture left child alive'
/usr/bin/flock -n /run/aboutme/workload.lock true || fail 'initial fixture left child alive'
[[ ! -s $work/initial-death-out ]] || fail 'initial parent death exposed success'
refuse bash "$wrapper" reconcile-initial; initial_reset; exec {initial_continue_fd}>&-
touch "$authority/restore-reconciliation"; chmod 0444 "$authority/restore-reconciliation"
NOTICE_LOCK=contention refuse bash "$wrapper" reconcile-initial
[[ -f $authority/restore-reconciliation ]] || fail 'lock contention cleared marker'
initial_reset; : >"$work/systemctl-calls"
before=$(wc -l <"$work/initial-calls")
NOTICE_INITIAL_SLICE=active NOTICE_LEGACY_PROTECTION=active app 0 reconcile-initial
[[ $(wc -l <"$work/initial-calls") == $((before + 1)) ]] || fail 'inert job slice blocked initial database proof'
[[ ! -e $authority/restore-reconciliation && ! -e /var/lib/aboutme/cutover-mutation.json ]] || fail 'initial success retained markers'
if grep -Eq '^(stop|restart).*crowdsec' "$work/systemctl-calls"; then fail 'initial reconciliation interrupted existing protection'; fi
cmp -s "$authority/initial-epoch" "$work/initial-current" || fail 'initial action changed anchor'
[[ ! -e $authority/send.json && ! -e $authority/activation.json ]] || fail 'initial success issued authority'
before=$(wc -l <"$work/initial-calls"); app 0 reconcile-initial
[[ $(wc -l <"$work/initial-calls") == $((before + 1)) ]] || fail 'absent marker bypassed database proof'
for fault in before-store after-rename after-sync lost-response; do
  NOTICE_INITIAL_RELEASE=$fault refuse bash "$wrapper" reconcile-initial
  [[ ! -e $authority/restore-reconciliation && ! -e $authority/send.json && ! -e $authority/activation.json ]] || fail 'uncertain release changed notice authority'
  if [[ $fault == before-store ]]; then
    jq -e '.operation_kind=="cutover"' /var/lib/aboutme/fence.json >/dev/null || fail 'failed release store lost owner'
    refuse bash "$wrapper" reconcile-initial
  else
    jq -e '(.operation_id // null)==null' /var/lib/aboutme/fence.json >/dev/null || fail 'uncertain release recreated owner'
  fi
  initial_reset; app 0 reconcile-initial
done
cp "$work/sealed" "$work/aggregate"; printf '2\n' >"$work/app-exit"
jq '.state="capturing" | .actual_count=0 | .counts.unqueued=0 | .sealed_at=null' "$work/sealed" >"$work/aggregate"
NOTICE_CAPTURE=1 app 2 prepare; [[ -f $authority/capture-in-progress && ! -s $authority/capture-in-progress ]] || fail 'pending capture lost marker'
[[ $(stat -c '%u:%g:%a:%h' "$authority/capture-in-progress") == 0:0:444:1 ]] || fail 'capture marker metadata'; NOTICE_APP_STATE=inspection-failure refuse bash "$wrapper" prepare
[[ -f $authority/capture-in-progress ]] || fail 'capture refusal lost marker'; cp "$work/sealed" "$work/aggregate"
jq '.result="sealed"' "$work/sealed" >"$work/aggregate"
printf '0\n' >"$work/app-exit"; NOTICE_CAPTURE=1 app 0 prepare; [[ ! -e $authority/capture-in-progress ]] || fail 'sealed capture retained marker'
jq '.result="sealed" | .expected_count=0 | .actual_count=0 | .counts.unqueued=0' "$work/sealed" >"$work/aggregate"
app 0 prepare; [[ ! -e $authority/capture-in-progress ]] || fail 'zero cohort did not seal'
cp "$work/sealed" "$work/aggregate"; printf '2\n' >"$work/app-exit"; app 0 authorize-send
[[ -f $authority/send.json ]] || fail 'send authorization missing'; cp "$authority/send.json" "$work/current-send"; app 2 enqueue
jq '.counts={unqueued:0,queued:1,accepted:0,deleted:0,failed:0,cancelled:0}' "$work/sealed" >"$work/aggregate"
app 2 enqueue
jq '.result="queue_full"' "$work/aggregate" >"$work/full"
cp "$work/full" "$work/aggregate"; app 2 enqueue; [[ ! -e $authority/activation.json ]] || fail 'queue wait activated ingestion'
cp "$work/sealed" "$work/aggregate"; app 2 activate; [[ ! -e $authority/activation.json ]] || fail 'unresolved ledger activated ingestion'
app 0 authorize-send; cp "$authority/send.json" "$work/current-send"
for mutation in '.extra=true' '.schema_version=2' '.expected_count=2' '.content_sha256=("0"*64)' '.state="aborted"' '.state="retired"' \
  '.cutoff_at="2026-10-19T01:02:03Z"' '.counts.failed=1' '.recovery_count=9223372036854775808' '.actual_count=0'; do
  jq "$mutation" "$work/sealed" >"$work/aggregate"
  invalid_aggregate; cmp -s "$authority/send.json" "$work/current-send" || fail 'invalid aggregate changed authority'
done
for contents in '{}' '{} {}' '{"schema_version":1,"schema_version":1}' '{bad}'; do
  printf '%s\n' "$contents" >"$work/aggregate"; invalid_aggregate
done
printf '\377\n' >"$work/aggregate"; invalid_aggregate; head -c 4097 /dev/zero >"$work/aggregate"; invalid_aggregate
cp "$work/sealed" "$work/aggregate"; NOTICE_APP_ERROR=1 invalid_aggregate; printf '0\n' >"$work/app-exit"; invalid_aggregate
printf '2\n' >"$work/app-exit"
cp /var/lib/aboutme/release.json "$work/current-release"
jq '.release_number=1' "$work/current-release" > /var/lib/aboutme/release.json
refuse bash "$wrapper" authorize-send; cp "$work/current-release" /var/lib/aboutme/release.json; cp "$work/units/aboutme-server.container" "$work/current-unit"
sed -i "s|$legacy_server|ghcr.io/dannyota/aboutme-server@sha256:$(printf '%064d' 9)|" "$work/units/aboutme-server.container"
refuse bash "$wrapper" authorize-send; cp "$work/current-unit" "$work/units/aboutme-server.container"
for mutation in '.epoch="00000000-0000-4000-8000-000000000000"' '.expected_count=2' '.content_sha256=("0"*64)' '.issued_at="9999-01-01T00:00:00.000000Z"' '.extra=true'; do
  jq "$mutation" "$work/current-send" >"$authority/send.json"
  chmod 0444 "$authority/send.json"; if [[ $mutation == '.expected_count=2' ]]; then invalid_aggregate enqueue; else refuse bash "$wrapper" enqueue; fi
done
printf '{}\n' >"$authority/send.json"; refuse bash "$wrapper" enqueue; cp "$work/current-send" "$authority/send.json"
jq '.result="activated" | .state="activated" | .counts={unqueued:0,queued:0,accepted:1,deleted:0,failed:0,cancelled:0}
  | .activation_count=1 | .first_activated_at="2026-10-19T01:02:05.000000Z"
  | .activated_at=.first_activated_at | .last_accepted_at=.first_activated_at' "$work/sealed" >"$work/aggregate"
cp /var/lib/aboutme/fence.json "$work/ceiling-fence"; /usr/bin/rm -f "$work/container-args"
release_fixture "$above_floor" "$above_release"; printf '0\n' >"$work/app-exit"; refuse bash "$wrapper" activate
grep -qxF activate "$work/container-args" && [[ ! -e $authority/activation.json ]] &&
  jq -e --slurpfile before "$work/ceiling-fence" '.operation_kind=="deploy" and .minimum_release==$before[0].minimum_release
    and .minimum_tag==$before[0].minimum_tag' /var/lib/aboutme/fence.json >/dev/null || fail 'activation above the tracked floor'
release_fixture "$floor_tag" "$floor_release"; cp "$work/ceiling-fence" /var/lib/aboutme/fence.json
cp "$work/current-send" "$authority/send.json"; chmod 0444 "$authority/send.json"
printf '0\n' >"$work/app-exit"; rm -f "$work/joined" "$work/stopped"; : >"$work/order"
NOTICE_CLAIMED=1 app 0 activate; [[ -f $authority/activation.json && ! -e $authority/send.json ]] || fail 'activation authority transition'
awk '$0=="stop" {stopped=NR} $0=="join" {joined=NR} $0=="rm send.json" {revoked=NR} END {exit !(stopped && joined>stopped && revoked>joined)}' \
  "$work/order" || fail 'claimed worker not joined before revocation'
cp "$authority/activation.json" "$work/current-activation"; app 0 activate; cmp -s "$authority/activation.json" "$work/current-activation" || fail 'reconstruction changed activation'
[[ $(date -u +%Y-%m-%d) == 2026-11-01 ]] || fail 'delayed activation clock'; rm "$authority/activation.json"; app 0 activate
cmp -s "$authority/activation.json" "$work/current-activation" || fail 'delayed reconstruction changed evidence'
touch "$authority/restore-reconciliation"; chmod 0444 "$authority/restore-reconciliation"; refuse bash "$wrapper" authorize-send; refuse bash "$wrapper" activate
rm "$authority/restore-reconciliation"
rm "$authority/activation.json"
jq '.result="blocked" | .state="sealed" | .activated_at=null | .last_accepted_at=null
  | .counts.accepted=0 | .counts.failed=1 | .failure_counts.delivery_failed=1' "$work/aggregate" >"$work/late-failure"
cp "$work/late-failure" "$work/aggregate"; printf '1\n' >"$work/app-exit"; app 1 activate
[[ ! -e $authority/activation.json && ! -e $authority/send.json ]] || fail 'late failure reopened authority'
for state in aborted retired; do
  jq --arg state "$state" '.result="blocked" | .state=$state | .activated_at=null
    | .aborted_at="2026-10-19T01:02:06.000000Z"' "$work/aggregate" >"$work/blocked"
  cp "$work/blocked" "$work/aggregate"; printf '1\n' >"$work/app-exit"; app 1 status; invalid_aggregate
  [[ ! -e $authority/send.json ]] || fail 'terminal campaign received send authority'
done
jq '.actual_count=0 | (.counts,.failure_counts) |= map_values(0) | .last_accepted_at=null' "$work/aggregate" >"$work/purged"
cp "$work/purged" "$work/aggregate"; app 1 status; invalid_aggregate
jq '.actual_count=2 | .counts.failed=2 | .failure_counts.delivery_failed=2' "$work/purged" >"$work/aggregate"; invalid_aggregate status
printf 'PASS notice guest filesystem protocol\n'; printf 'notice reconciliation: synthetic initial proof only\n'
