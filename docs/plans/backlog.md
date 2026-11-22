# Backlog

Open items that outlived their shipped plans. One line each, with the evidence that the item is still open. Delete a line when its work ships.

## Code

- The render harness's photo fixture (`apps/web/app/pages/_harness/photo-fixture.ts`) is a truncated 192 × 192 PNG: only rows 0 to 74 decode, because row 75 carries an invalid filter byte, so every harness photo paints only the top 40.9 px of its 96 px box and leaves an empty area below it (found 2026-11-18 in the web layout review). Repair it in its own change and regenerate every golden and the public corpus html that carry it.

- The editor HTTPS proof intermittently loses `aboutme-locale=en` during reauthentication (pull request run 44021348952, job 133831817300), although `signInWithGoogle` pins English before opening login. Direct logout sends `Clear-Site-Data`; session expiry does not, and real-user logout restores the locale through `useAuth`. Investigate the timing in a browser proof before changing the product or proof.

- [Local tooling](../design/local-tooling-simplification.md#owner-choices-and-combined-jobs), accepted 2026-11-01, is partly built: display assertions have landed, while portable sessions, the wrapper and lock changes (`instructions/resources.md` still gives the interim command), strict native Mac HTTPS, and the `server-runtime-smoke` CI job (absent from `.github/workflows/ci.yml`) are pending. Preserve exact-commit release CI.

## Production acceptance

- Dispatch the first `action=renew` of `.github/workflows/vmonitor-renew.yml` from 2026-11-24T06:54:54Z (the 7-day threshold for the term ending 2026-12-01T06:54:54Z) and confirm the later expiry by read-back; then add the schedule in a separate reviewed change. `action=check` passed on 2026-11-01 (run 41302010198) and the owner delegated closing hold issue #146, which is now closed. If the renewal fails or stays unconfirmed, reconcile with the provider before any retry. Evidence: [renewal design](../design/vmonitor-quota-renewal.md).
- Serving and maintenance Caddy share one bouncer key and so one LAPI stream cursor (`Secret=crowdsec-bouncer-key` in both `deploy/vn/host/quadlet/aboutme-caddy.container.in:16` and `aboutme-maintenance.container.in:16`). A maintenance edge that pulls the stream can advance the cursor the serving edge depends on. Give each edge its own bouncer, or prove the shared cursor is safe across edge switches.

## Vietnam production

- The lock wrapper's run-owned check gives `ps -axo …` 2 s; at load 14 on the Ubuntu host it stalled past that once and `make web-lint` exited 126 before lint ran. Raise the bound or retry once, and report the stall as a wrapper error rather than a check failure.

## Acceptance evidence gaps

- qa: retained production proof of fence state and TOTP with `scripts/totp-production-proof.sh totp-prod-enabled` (AC-SEC-007, AC-SEC-009); retain a Vietnam direct-edge probe that reaches Caddy at the host IP with the apex hostname and confirms Caddy uses the socket client address and strips spoofed forwarding headers. Evidence: `deploy/caddy/production/edges/direct.sites`. The probe closes AC-INF-001.
- AC-INF-012 to 014 (Vietnam edge, secret custody, alarms) are `LANDED` and each names its missing proof: the issued certificate chain and DNS-only records, a production listing of secret file modes and unit secret sets, and one delivered alert per channel. Collect them read-only with qa.
