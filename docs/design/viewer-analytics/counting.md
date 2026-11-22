# Counting real views

A view counts when a real browser shows a live resume for a while and a person
interacts with it. Five layers remove automation without fingerprinting. They
keep the numbers 1 and 4 to 7 from
[ADR 0022](../../adr/0022-viewer-privacy-and-counting.md#counting-layers);
layers 2 and 3 were AWS edge labels that direct delivery never had. The count is
a number per resume per day, with no cookie and no stored personal data
([ADR 0022](../../adr/0022-viewer-privacy-and-counting.md)).

## Flow

```mermaid
sequenceDiagram
  participant B as Browser (public-resume.mjs)
  participant C as Caddy
  participant G as Go
  B->>C: GET /{slug}
  C->>G: HTML request; Go classifies the user agent
  G-->>B: Resume HTML (unchanged, shared by all viewers)
  B->>G: POST /api/v1/public/resumes/{slug}/views/start
  G-->>B: sealed view token and proof-of-work challenge, or the owner flag
  Note over B: solve proof of work in the background;<br/>wait for 8 s visible and one trusted interaction
  B->>C: POST /api/v1/public/views/collect
  C->>G: collect
  G->>G: verify token, proof, timing, dedupe, owner, anomaly
  G-->>B: 204
```

The resume HTML stays identical for every viewer, so the in-process public cache
and `ETag` revalidation keep working
([ADR 0010](../../adr/0010-public-artifact-revocation.md)). The token is
therefore issued by the page's own script when the page loads, not embedded in
the HTML.

## Layers

| #   | Layer                  | Rule                                                                                                                                                                                                 | Outcome when it fails                   |
| --- | ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------- |
| 1   | Known crawlers         | Go matches the HTML request's user agent against a committed list. Link-preview fetchers become share signals; search engines and other self-declared bots become `crawler`. Neither runs the script | Share signal or `crawler`, never a view |
| 4   | Visible time and input | The script sends collect only after 8 s of cumulative visible time (Page Visibility API) and at least one trusted (`isTrusted`) scroll, pointer, touch, or key event                                 | No collect; not counted, not filtered   |
| 5   | Sealed one-time token  | Issued by start, sealed with AES-GCM, bound to the resume; accepted 8 s to 30 min after issue, once                                                                                                  | `invalid`                               |
| 6   | Proof of work          | An ALTCHA v2 challenge from start, solved in the page's main thread, verified by Go                                                                                                                  | `invalid`                               |
| 7   | Dedupe, owner, anomaly | One counted view per network per resume per day; the owner's own views are dropped; views above the hourly cap become anomalies                                                                      | Not counted, or `anomaly`               |

A view that passes every layer is `counted`. The owner sees `counted` as N and
the sum of `bot`, `datacenter`, `anomaly`, `invalid`, and `crawler` as M; `bot`
and `datacenter` stay in the API and always read 0 on direct delivery. Layer 4
failures are people who left quickly or never touched the page; they are neither
counted nor filtered.

### Layer 1: crawler list

`apps/server/internal/viewcount/crawlers.go` holds a closed, tested list of user
agent tokens mapped to a platform: `facebookexternalhit` and `Facebot`
(Facebook, Messenger, and iMessage, which sends the same token), `LinkedInBot`,
`Twitterbot`, `TelegramBot`, `WhatsApp`, `Slackbot-LinkExpanding` and
`Slack-ImgProxy`, `Discordbot`, `SkypeUriPreview`, `Viber`, and Zalo's fetcher
(token **Verify** with the Zalo sharing debugger during the live checks). Search
engines (`Googlebot`, `bingbot`, `coccocbot`, `Applebot`, `DuckDuckBot`) and
generic tokens (`bot`, `spider`, `crawl`, `curl`, `python-requests`,
`Go-http-client`, `HeadlessChrome`) are `crawler`. The platforms are those in
[link previews](../link-previews.md#platforms).

Share signals count preview fetches, deduplicated per platform per resume per 10
minutes in memory. A fetch is a proxy for a share: platforms cache previews, and
one share may fetch twice. Anyone can send a platform's user agent, so the
signal is labelled "link previews", not "shares".

### Layer 4: visible time and interaction

The script accumulates time while `document.visibilityState` is `visible`. It
listens once, passively, for trusted `scroll`, `pointerdown`, `touchstart`, and
`keydown` events. It sends nothing about the events except that the threshold
passed. **8 seconds** is inside the owner's 5 to 10 second range: long enough to
skip a glance, short enough for a one-page resume. The server rejects a collect
that arrives less than 8 s after its token, whatever the script claims.

### Layers 5 and 6: token and proof of work

Start returns:

- `token`: base64url of AES-256-GCM over
  `resumeID (16 bytes) ‖ issuedAt Unix milliseconds (8) ‖ viewID (16)`, with a
  12-byte nonce. The GCM tag authenticates the token and the encryption keeps
  the resume ID from the viewer, so no extra resume column is needed. The key is
  32 random bytes made at process start and never stored, so a deploy ends
  outstanding tokens; those views are lost, not double counted.
- `challenge`: an ALTCHA v2 challenge from
  `github.com/altcha-org/altcha-lib-go/v2` (MIT), algorithm `PBKDF2/SHA-256`,
  cost 1,000, key length 32, HMAC-signed with a second per-process key. The
  server picks the counter uniformly in 200 to 999, so the client derives about
  600 keys on average while the server verifies with one HMAC over the derived
  key ([ALTCHA Go][altcha-go]). The signed `data.view` field carries the view
  ID, so a solved challenge works only with its own token. Go refuses a
  challenge without a key signature, which the library would otherwise accept on
  its signature alone.

The script solves the challenge with `altcha-lib`'s `solveChallenge` (MIT) on
the main thread through Web Crypto, without the widget and without a Web Worker,
so the public page CSP keeps `worker-src 'none'` ([ALTCHA JS][altcha-js]). The
cost targets a median of at most 1 s on a mid-range 2021 Android phone
(**Verify** on a real phone during the live checks; the parameters are in
[budgets](../budgets.md#viewer-analytics)). No third party is contacted:
ALTCHA's hosted Sentinel is not used.

Collect checks, in order: body shape, the token's GCM tag, token age within 8 s
to 30 min, the view ID unused, and the challenge signature, binding, and
solution; none of these needs the database. Only then is the view ID marked
used, so reports without work cannot fill the used-ID set, which holds each ID
for 30 minutes. A report that passed them costs one live-gate read, then the
owner check and the edge headers apply. A failure of an unexpired token records
`invalid`, without the live gate; an expired token, or one that does not open,
records nothing; a malformed body is a 400 and records nothing.

### Layer 7: dedupe, owner, anomaly

- **Each outcome once:** every outcome, counted or filtered, is recorded at most
  once per network per resume per day, so repeated reports cannot inflate either
  number.
- **Network key:** `HMAC-SHA-256(dayKey, network ‖ resumeId)`, where the network
  is the IPv4 address or the IPv6 /64, and `dayKey` is 32 random bytes made in
  memory at the first request of each Asia/Ho_Chi_Minh day and dropped at the
  end of it. A bounded map holds the keys for the day. The first valid collect
  for a key counts; later ones on the same day record nothing. The key, the map,
  and `dayKey` are never written to disk, logs, or the database.
- **Owner:** start and collect read the `__Host-session` cookie through the
  optional session check, which may refresh a rotated cookie but authorizes
  nothing. When the session's account owns the resume, collect records nothing
  and the network key is marked `owner` for the rest of the day, so the owner's
  later signed-out views from the same network are not counted either. Start
  does the same when it sees the owner's session, and answers with the owner
  flag and no token, so the owner's own page sends nothing.
- **Anomaly:** a resume counts at most 30 views in any clock hour; further valid
  views that hour record `anomaly`. The cap is in [budgets](../budgets.md).

A restart loses the day's map, so a person who views before and after a deploy
may count twice that day. Production has one replica
([ADR 0025](../../adr/0025-replica-scaling.md)); a second replica needs a shared
dedupe store ([scaling](../scaling/README.md)).

## Aggregation

Go keeps counts in a bounded in-memory buffer keyed by resume, day, and outcome,
and flushes it every 60 s and at graceful shutdown with one batched upsert per
table into `resume_view_days` and `resume_share_signal_days`
([delivery](delivery.md#schema)). A crash, or a failed write, loses at most 60 s
of counts; a failed batch is dropped, not retried. A resume that is unpublished
or deleted between start and collect records no view: collect re-checks the live
gate before any view outcome, and the upsert skips a resume deleted before the
flush. Only an `invalid` from a token under 30 minutes old can land on such a
resume. Days use the Asia/Ho_Chi_Minh zone, a fixed UTC+7.

## What the owner sees

The Views page (`/app/views`) lists every resume that is live or has counts,
with its counts for the last 7, 30, and 90 days, and links to a resume page
(`/app/views/{id}`) with:

- the headline for 90 days (**Owner approval** V2): "N lượt xem thật · M bị lọc"
  / "N real views · M filtered";
- a daily bar chart of real views for 90 days, and a 12-month monthly total;
- M, with the breakdown: bots, hosting networks, anomalies, failed checks, and
  crawlers;
- link previews by platform: "Xem trước liên kết trên Zalo × 3" / "Link previews
  on Zalo × 3", with the note that one share can fetch more than once;
- the definition line (**Owner approval** V2): "Mỗi kết nối mạng được tính tối
  đa một lượt xem mỗi ngày. Hai người dùng chung một kết nối mạng trong một ngày
  được tính một lần; một người xem vào hai ngày được tính hai lần." / "One view
  per network per day. Two people on one network in one day count once; one
  person on two days counts twice."
- the honest-limit line: "Số liệu chỉ loại được những gì bộ lọc phát hiện; công
  cụ tự động tinh vi vẫn có thể được tính." / "Counts exclude only what the
  filters detect; sophisticated automation can still be counted."

The page reads only aggregates. Resume pages show the 90 days ending today, and
the list page the 7, 30, and 90 days ending today, all in Asia/Ho_Chi_Minh days.

## Honest limit

These layers stop self-declared bots, HTTP libraries, headless scripts that do
not run the page, most data-center automation, replayed or forged beacons, and
quick scrapers. They do not stop a person, or a paid service, that drives real
browsers from residential networks, waits, interacts, and solves the proof of
work. Counts are a floor where many people share one network, such as mobile
carrier NAT in Vietnam, and they may include such sophisticated automation. Only
the owner sees counts, so inflating them gains little outside the owner's own
view.

[altcha-go]: https://github.com/altcha-org/altcha-lib-go
[altcha-js]: https://github.com/altcha-org/altcha-lib
