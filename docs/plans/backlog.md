# Backlog

Open items that outlived their shipped plans. One line each, with the evidence that the item is still open. Delete a line when its work ships.

## Code

- The render harness's photo fixture (`apps/web/app/pages/_harness/photo-fixture.ts`) is a truncated 192 × 192 PNG: only rows 0 to 74 decode, because row 75 carries an invalid filter byte, so every harness photo paints only the top 40.9 px of its 96 px box and leaves an empty area below it (found 2026-11-18 in the web layout review). Repair it in its own change and regenerate every golden and the public corpus html that carry it.

- vue-router 5.5 saves scroll positions to `sessionStorage` (`"vue-router:scroll"`), which breaks `docs/design/showcase-contract.md:61` (the page stores nothing in browser storage) and is not in the privacy notice; `apps/web` holds vue-router at 5.4.0 and `.github/dependabot.yml` ignores `>=5.5.0`. Decide whether to disable it in product code or accept and document it before raising the pin.
- The editor HTTPS proof's `session-reauthenticated` stage fails intermittently: the `aboutme-locale=en` cookie that `pinEnglish` sets is gone after reauthentication, so the login page renders in Vietnamese and the English heading wait times out (`editor-diagnostic.json` from pull request run 44021348952, job 133831817300). Find what clears the cookie: if sign-out or session end clears it for real users, fix the product; otherwise fix the proof.

- [Local tooling](../design/local-tooling-simplification.md#owner-choices-and-combined-jobs), accepted 2026-11-01, is partly built: display assertions have landed, while portable sessions, the wrapper and lock changes (`instructions/resources.md` still gives the interim command), strict native Mac HTTPS, and the `server-runtime-smoke` CI job (absent from `.github/workflows/ci.yml`) are pending. Preserve exact-commit release CI.

- The signed-in header overflows by 27 px in English at 640 px wide, before and after the Projects link was added (measured in `apps/web/e2e/projects.spec.ts` runs on 2026-11-11, which therefore asserts only the page column at that width). It fits from 700 px, and Vietnamese fits everywhere.

- The photo panel's Retry button stays enabled while its resend is in flight; the queue ignores the repeat, so nothing is sent twice, but the control should be disabled like the held-write alert's (`apps/web/app/components/editor/photo/PhotoPanel.vue`).
- History panel on phones: after a version read answers 404, focus drops to the page body because the focus request runs before the Edit tab shows (`apps/web/app/composables/useEditorHistory.ts`); a restore confirm blocked by unsaved work or a failed session check does nothing and the dialog gives no reason (`apps/web/app/editor/historyController.ts`). Move focus after the tab switch, and show the blocked reason.
- The published ci-tools package still holds the `hashicorp/aws` provider zip and its `SHA256SUMS` line; the action and tests no longer pin it, and the old package keeps working. Drop the zip at the next ci-tools republish made for another reason.
- The web deployment decoder's version pattern accepts leading zeros that `deploy/observer/schema/deployment.v1.json` rejects (`apps/web/app/utils/deploymentDocument.ts`). Use the schema's `(0|[1-9][0-9]*)` form.
- Nothing validates `apps/web/e2e/fixtures/deployment/*.json` against `deploy/observer/schema/deployment.v1.json`, and `deploy/observer/README.md` and `AGENTS.md` wrongly say the frontend reads `testdata/examples/`. Add a schema check for the fixtures and correct the text.
- Fold Dependabot pull requests #266, #273 (vitest 5, drop it if it breaks), #308, #309 and #310 and the open alerts with patches (`minimatch` in `pnpm-lock.yaml`; `go.opentelemetry.io/otel` in `deploy/caddy/production/build/go.mod`) into one dependency change, then close the pull requests. The `go-jose/v3` alerts in the Caddy build have no patch: check whether a newer Caddy drops it.

## Production acceptance

- Dispatch the first `action=renew` of `.github/workflows/vmonitor-renew.yml` from 2026-11-24T06:54:54Z (the 7-day threshold for the term ending 2026-12-01T06:54:54Z) and confirm the later expiry by read-back; then add the schedule in a separate reviewed change. `action=check` passed on 2026-11-01 (run 41302010198) and the owner delegated closing hold issue #146, which is now closed. If the renewal fails or stays unconfirmed, reconcile with the provider before any retry. Evidence: [renewal design](../design/vmonitor-quota-renewal.md).
- Serving and maintenance Caddy share one bouncer key and so one LAPI stream cursor (`Secret=crowdsec-bouncer-key` in both `deploy/vn/host/quadlet/aboutme-caddy.container.in:16` and `aboutme-maintenance.container.in:16`). A maintenance edge that pulls the stream can advance the cursor the serving edge depends on. Give each edge its own bouncer, or prove the shared cursor is safe across edge switches.

## Vietnam production

- The lock wrapper's run-owned check gives `ps -axo …` 2 s; at load 14 on the Ubuntu host it stalled past that once and `make web-lint` exited 126 before lint ran. Raise the bound or retry once, and report the stall as a wrapper error rather than a check failure.

## Acceptance evidence gaps

- qa: retained production proof of fence state and TOTP with `scripts/totp-production-proof.sh totp-prod-enabled` (AC-SEC-007, AC-SEC-009); retain a Vietnam direct-edge probe that reaches Caddy at the host IP with the apex hostname and confirms Caddy uses the socket client address and strips spoofed forwarding headers. Evidence: `deploy/caddy/production/edges/direct.sites`. The probe closes AC-INF-001.
- AC-INF-012 to 014 (Vietnam edge, secret custody, alarms) are `LANDED` and each names its missing proof: the issued certificate chain and DNS-only records, a production listing of secret file modes and unit secret sets, and one delivered alert per channel. Collect them read-only with qa.
