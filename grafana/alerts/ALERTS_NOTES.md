# AV Tools — Alerts update (PROD + QA, per-device)

Three rule groups, one source of truth per group. QA is **derived from PROD at
deploy time** by `scripts/patch_grafana_rulegroup.py` — there are no
hand-maintained QA payloads to drift. The existing DQ group changes in exactly
**one** way: an `av_alert_type` label is added to every rule for
notification-policy routing.

## Rule groups

| Group (PROD) | Source file | Interval | Rules | `av_alert_type` |
|---|---|---|---|---|
| `avtools-eam-dq-weekly` *(existing)* | `grafana/alerts/avtools-eam-dq-weekly.rulegroup.PUT.json` | `604800` (weekly, unchanged) | 14 (unchanged) | **+`inventory`** |
| `avtools-not-networked` *(new)* | `grafana/alerts/avtools-not-networked.rulegroup.PUT.json` | `604800` (weekly) | 1 — Alert 1 | `inventory` |
| `avtools-network-state` *(new)* | `grafana/alerts/avtools-network-state.rulegroup.PUT.json` | `300` (5 min) | 2 — Alerts 2 + 3 | `operational` |

The QA equivalents (`*-qa` groups in the **playground** folder) are produced by
the patcher and previewed under `review/qa/` for inspection.

## The three new alerts

1. **Devices not networked (absent from Prometheus)** — `avtools-not-networked`.
   Pure-Postgres anti-join: active `eam_devices` with no row in
   `landb_ipaddresses` (no LanDB IP ⇒ never scraped ⇒ never in Prometheus).
   Grafana cannot string-key-anti-join Postgres against Prometheus, so this is
   expressed entirely in SQL, which faithfully equals "not networked". Weekly —
   it is a slow inventory condition.
2. **Devices offline (latest ping state)** — `avtools-network-state`.
   `(max by (equipmentno) (last_over_time(avtools_ping_check_status{submitter_environment="prod"}[30d])) == 0) + 1`.
3. **Online devices without SNMP** — `avtools-network-state`.
   `(… ping == 1) and (… snmp_probe_status == 0)` — online **and** SNMP-down.

Join key is **`equipmentno`** throughout (the EAM primary key and the mandatory
Prometheus label). Serial number is not a Prometheus label, so a serial-based
match is impossible; `equipmentno` is the correct, robust key.

## Per-device firing

Every new rule emits **one alert instance per `equipmentno`**, not an aggregate
count:

- **Alert 1 (SQL)** returns one row per device — columns `equipmentno` (becomes
  the series label) + `value = 1`; threshold `gt 0` fires per row.
- **Alert 2 (PromQL)** yields one series per offline device, value 1.
- **Alert 3 (PromQL)** yields one series per device that is online **and**
  SNMP-down; offline devices are excluded by the online-gate (`and`).

`noDataState` is **`OK`** on the three new rules (not `NoData` like the DQ
rules): a per-device filter returns an empty frame when the whole fleet is
healthy, and `OK` makes that read as Normal rather than NoData. The DQ rules are
untouched and keep `NoData`.

## Labels → notification policies (manual UI step)

The cadence you want (daily reminders for operational, weekly→monthly for
inventory) is **`repeat_interval`, which lives in Notification policies, not in
the rule JSON**. Add two child policies under the default policy:

| Matcher | repeat_interval | Group by | Covers |
|---|---|---|---|
| `av_alert_type = operational` | `1d` | add `equipmentno` | offline / SNMP (`avtools-network-state`) |
| `av_alert_type = inventory` | `4w` | add `equipmentno` | DQ + not-networked |

Two reminders from the policy screen you shared:

- The **default policy repeat interval is `52w`** today (effectively
  fire-once). The child policies above override it for these alerts.
- Default grouping is `grafana_folder, alertname`. For per-device alerts you
  must **add `equipmentno` to the grouping** (toggle "Override grouping"), or
  Grafana bundles every firing device for one alertname into a single
  notification and you lose per-device granularity.

## PROD vs QA — the deterministic transform

`patch_grafana_rulegroup.py <env> <src> <out>` renders a PROD source for `prod`
or `qa`. QA = PROD with exactly these substitutions:

| Aspect | PROD | QA |
|---|---|---|
| Folder UID | `beuar1of5bo5cf` (av-dashboard) | `7BZSQJX4z` (**playground**) |
| Group name | `<base>` | `<base>-qa` |
| Rule UID | `<uid>` | `<uid>-qa` |
| Rule title | `AV Tools: …` | `QA - AV Tools: …` |
| Receiver | `AV Tools` | `AV Test` |
| Postgres datasource | `ed690575-…-81f47592f349` | `dfaue906qonpcf` |
| Dashboard link `__dashboardUid__` | `av_devices_dashboard` | `av_devices_dashboard-qa` |
| PromQL `submitter_environment` | `"prod"` | `"qa"` |
| Prometheus datasource | `afcql1n10tnggc` (shared — **not** rewritten) | same |
| Group `interval` | per file | same as PROD |

The transform is bijective and idempotent: `prod(source) == source` (modulo the
server-assigned `id`, which is intentionally stripped), `qa(qa(x)) == qa(x)`, and
`prod(qa(x)) == prod(x)`.

## Existing QA DQ group — update in place, no duplicate

The QA DQ group `avtools-eam-dq-weekly-qa` already exists in **playground**. The
QA render produced here carries the **same rule UIDs** (`afccb41r2fjswd-qa`, …)
and the same group/folder, so a PUT **updates the existing rules in place** and
simply adds `av_alert_type: inventory`. It does not create a second copy. (Grafana
identifies provisioned rules by UID; the "Provisioned" badge you see is the
provisioning-API provenance — the same flow these scripts use.)

## Deploy

CI (recommended) — two new **manual** jobs, separate from the dashboard deploys:

- `deploy_grafana_alerts_qa` (stage `deploy_qa`) → `sync_grafana_rulegroup_qa.sh put`
- `deploy_grafana_alerts_prod` (stage `deploy_stable`) → `sync_grafana_rulegroup.sh prod`

Each publishes **every** `grafana/alerts/*.rulegroup.PUT.json` (3 groups),
deriving QA on the fly. Trigger from the pipeline's manual ▶ buttons.

Local (same scripts):

```bash
export GRAFANA_API_TOKEN="<service-account token for the target org>"
./scripts/sync_grafana_rulegroup.sh qa     # or: prod | both
```

## Validated here vs needs your live stack

Verified in this bundle: all payloads are valid JSON; the PROD DQ file is the
committed file **plus the label, nothing else** (zero other diffs); the QA
renders match the existing playground group exactly (UIDs/titles/receiver/folder)
plus the label; the QA env transform is correct (QA Postgres UID, `qa` env label
in PromQL, `-qa` groups/UIDs, `-qa` dashboard links, no PROD datasource string
leaks into QA); per-device output and `gt 0` condition wiring confirmed; the
not-networked SQL output columns are `[equipmentno, value]`.

Needs your stack: run the two PromQL exprs in Explore against Mimir (prod + QA)
and confirm the per-device series match the dashboards; confirm a few
`equipmentno`s from Alert 1 genuinely have no LanDB IP; after wiring the
policies, fire a test (pause/unpause, or a known-offline device) to confirm one
notification per device at the expected repeat interval.

## Tunables

- `interval`: `604800` (not-networked / DQ), `300` (network-state). Keep
  divisible by the 10s scheduler tick.
- `for`: `0s` (matches existing). Raise on the operational rules to require a
  sustained state if you see flapping.
- `[30d]` lookback: latest-known-state window, consistent with the dashboards.
  Shorter = stricter "recently offline"; longer = "last known". A withdrawn
  device lingers until its sample ages out.
- Per-device cardinality: Alert 1 can fire for many devices at once. The planned
  EAM model change (a "not-networkable / monitoring-exempt" flag) will let you
  exclude devices that legitimately cannot be networked; the SQL's
  `active_devices` CTE is where that exclusion goes.

## Absence vs. zero — the `noDataState` trap (2026-07-30 outage)

**A multi-day total collection outage in both PROD and QA produced zero fired
alerts.** Every pod reported success; the outage was found by a human noticing
blank dashboard panels. This section is the durable lesson so nobody
reintroduces the bug. Read this before adding any new rule over
`avtools_snmp_devices_*`, or any metric that can stop being emitted entirely.

**Mechanism:** an upstream LanDB API failure emptied the device-fleet cache;
the reconcile step then deleted the whole fleet table and still exited
`status=ok` (no failure signal). The next collection cycle saw zero targets
and short-circuited on `skipped_no_targets` — **before** the point in the code
where `avtools_snmp_devices_targeted` / `_polled` / `_coverage_ratio` get
published. The series did not read `0`. It stopped existing.

**Why that defeats a naive threshold rule:** `sum()`, `count()`, and a ratio
like `sum(polled)/sum(targeted)` all operate on whatever series currently
exist. If the input series are entirely absent, these aggregations return an
**empty result set** — Grafana's "NoData" — not a `0` or a `0/0`. `noDataState:
OK` tells Grafana "an empty result here means the system is healthy," which is
exactly backwards for these metrics: the *only* reason
`avtools_snmp_devices_targeted` stops being emitted at all is that collection
itself is broken. Absence is a stronger, worse signal than a bad number, and
`OK` was silently converting the worst-case outage into a green dashboard.

**The one-line test before you set `noDataState: OK` on a new rule:** *"Can
this series legitimately disappear for a reason other than the failure I'm
trying to catch?"* If no — if vanishing IS the failure — `noDataState` must
never be `OK`. Use `Alerting` (this repo's default choice) unless there is a
genuine, deliberate, recurring idle window for that specific rule (there isn't
one for the SNMP fleet metrics today: QA runs a real ~1372-device fleet on the
same 5-minute cycle as PROD, so "no data" is never an expected steady state in
either environment).

**Two different fixes for two different failure modes, both required:**

1. **Absence** — fixed by `noDataState`. Changed `OK` → `Alerting` on
   `avtools-slo.rulegroup.PUT.json` (`AV SLO: Collection Coverage Below 99%`,
   `AV SLO: Collection Coverage Below 95%`, `AV SLO: Targeted Device Count
   Dropped`) and `avtools-k8s-slo.rulegroup.PUT.json` (`AV SLO: Blind Shard`).
   These four all aggregate over a metric that can vanish outright, and their
   `noDataState: OK` was the direct cause of the silent outage.
2. **Explicit zero** — NOT fixed by `noDataState`, because a real sample
   with value `0` is present data, not absent data. An app-side change
   (tracked separately) will make the skipped-fleet path publish an explicit
   `0` instead of dropping the series. Once that ships, the coverage-ratio
   rules would see `sum(polled)/sum(targeted)` as a literal `0/0`, which
   Prometheus evaluates to `NaN` — and Grafana's threshold evaluator treats a
   `NaN` comparison (`lt 0.99`, etc.) as **false**, i.e. Normal, not Alerting
   and not NoData. A ratio rule can go silent again on a clean explicit zero
   even with `noDataState: Alerting` fixed. That's why `AV SLO: Targeted Fleet
   Empty (Zero Devices for 10m)` (`avslofleetempty`) exists as its own rule: it
   queries the raw `sum(avtools_snmp_devices_targeted{...})` — no division —
   and applies Grafana's `eq 0` evaluator directly to it, plus
   `noDataState: Alerting`. That combination fires identically whether the
   series is absent (pre-fix, or any future regression that drops it again)
   or present-and-zero (post-fix). Do not add a "just check `== 0`" guard by
   dividing anything by the metric; query it raw and compare with the
   Grafana evaluator instead, or the same `NaN` trap resurfaces.

**What was already correct, and why — don't "fix" these by analogy:**
`AV SLO: SNMP Collection Stale (No Cycle in 10m)` and `AV SLO: LanDB Inventory
Sync Stale (No Success in 10m)` keep `noDataState: OK`. Their PromQL is
`absent_over_time(metric[10m])`, which is the inverse trick: it converts
absence itself into an explicit numeric sample (`1`) *inside the query*, so by
the time Grafana's evaluator runs, data is never actually missing — there is
always a real number to test with `gt 0`. The trap in this document is about
rules where Grafana's own no-data handling is the only thing standing between
an absent series and a fired alert; these two rules never put Grafana in that
position, so leave their exprs and `noDataState` alone.

**`execErrState` is intentionally untouched (`Error` everywhere).** It governs
query/datasource execution failures (timeouts, malformed queries, the
datasource being unreachable), which is a different failure axis from a
metric's absence. `Error` already fails loud/visibly and is consistent across
every rule in this repo; there is no absence-vs-zero interaction here to fix.

---

## The `tier` label trap — tier-aware SLO rules (2026-07-30, `feat/tier-aware-slo-alerts`)

*Scope: `avtools-slo.rulegroup.PUT.json` and `avtools-k8s-slo.rulegroup.PUT.json`
only. Read this together with the `noDataState` section above — the two traps
compose, and several rules below are only safe because of how they interact.*

### What changed underneath the alerts

The single `snmp-timeseries` CronJob (`*/5`, 8 shards x 16 threads, `--priority
all`) is being replaced by **four** CronJobs that each run the **same full sweep
over the same 1375-device fleet** and publish only their own metric tier:

| tier | schedule | shards x threads | sweep | `activeDeadlineSeconds` |
|---|---|---|---|---|
| critical | `*/5` | 8 x 16 | ~40s (measured) | 150 |
| high | `3-59/15` | 4 x 16 | ~80s (projected) | 220 |
| medium | `7 * * * *` | 4 x 8 | ~160s (projected) | 320 |
| low | `11 */6 * * *` | 2 x 8 | ~320s (projected) | 1200 |

Sizing model: `duration ~= 3.7s x (devices / threads)`.

The cycle guardrails (`avtools_snmp_devices_targeted`, `_polled`,
`_coverage_ratio`, `avtools_snmp_cycle_duration_seconds`) are `Priority.ALWAYS`,
so **all four tiers emit all of them every cycle**. To stop the four emitters
colliding on one series identity the app attaches a conditional **`tier`** label
(value = the `--priority` token) — **only when `--priority != "all"`** — beside
the existing conditional `shard` label (present when `shard_total > 1`).

### The trap: `tier` does not exist yet

Production still runs `--priority all`, so **no `tier` label exists on any series
today**, and the tiered CronJobs may deploy days after these rules do. Every rule
must therefore be correct in three states: before the split, during a partial
rollout, and after.

| Idiom | Before the split | After | Verdict |
|---|---|---|---|
| `by (tier)` | every series has an absent/empty `tier`, all collapse into ONE unlabelled instance — reads exactly like the untiered rule | splits into one instance per tier | **safe** |
| `{tier=~"critical\|"}` | the empty alternation branch matches series with no `tier` label, i.e. everything | matches only `tier="critical"` | **safe** |
| `{tier="critical"}` | matches **nothing** | matches critical | **UNSAFE — never use** |

Why the bare equality matcher is a live grenade, in two different ways:

1. With `noDataState: Alerting` it selects nothing, the rule evaluates to NoData,
   and NoData means Alerting — **an immediate false page**, from the very commit
   that deploys it, for as long as the split takes to ship.
2. With `absent_over_time()` it is worse and inverted: `absent_over_time` of a
   selector that matches nothing returns **`1`**, a real sample, so the rule
   fires *through* `noDataState` entirely. No `noDataState` value can save it.

**Rule: in these two files, a `tier` matcher is always a regex with an empty
alternation branch (`tier=~"critical|"`), or the rule is deliberately dormant
(see below). Never `tier="..."`.**

The regex is anchored (`^(?:critical|)$`) and a series with no `tier` label is
matched as `tier=""`, which is what the empty branch selects. The selector stays
valid because the metric name is a non-empty matcher.

Reading of the empty branch: **today's single `--priority all` job is the
critical tier's predecessor** — same `*/5` schedule, same 8 x 16 sizing, same
fleet. So `tier=~"critical|"` is not a hack, it is the honest statement "the
critical-cadence sweep, whatever it is currently called".

Known limitation of the empty branch, accepted deliberately: any *untiered*
emitter (a manual `--priority all` run) satisfies **all four** per-tier freshness
rules at once, because it matches every `tier=~"<t>|"` selector. Do not leave an
untiered job scheduled alongside the tiered ones.

### Deliberately dormant rules — and why `noDataState: OK` is right there

Six rules use a **strict** matcher with no empty branch
(`tier=~"high|medium|low"`, `tier=~"high"`, `tier=~"medium"`, `tier=~"low"`,
`tier=~"high|medium"`): `avslok8sblindshardslow`, `avslok8ssweepbudget{high,
medium,low}`, `avslok8sshardskew{highmed,low}`. They select nothing until the
split and are silent — safe **only because all six carry `noDataState: OK`**.

That is not a regression of the absence-is-broken rule established earlier in
this document; it passes that section's own one-line test — *"can this series
legitimately disappear for a reason other than the failure I am trying to
catch?"* — with a loud **yes**. Prometheus keeps a sample current for ~5 minutes.
A tier that publishes once an hour therefore has a **live series for ~5 of every
60 minutes**, and the 6-hourly low tier for ~5 of every 360. Absence is the
*normal* state for these tiers, so `Alerting` on NoData would page ~92% and ~99%
of the time respectively.

Absence for those tiers is caught instead by the four
`AV SLO: SNMP Collection Stale (<tier> Tier, ...)` rules, which use
`absent_over_time` — the idiom that converts absence into an explicit `1` inside
the query and never puts Grafana's no-data handling on the critical path.

**Do not copy the strict-matcher pattern onto a rule whose `noDataState` is
`Alerting`.** The four rules that keep `Alerting` (`avslocoverage{warn,crit}`,
`avslotargetdrop`, `avslofleetempty`, `avslok8sblindshard`) all use either
`by (tier)` or an empty-branch matcher, so they select data in every state.

### The second trap this exposed: a filtering comparison is NoData when healthy

`avslotargetdrop` and `avslok8sblindshard` were `A < B` / `count(...) <
max_over_time(...)` — **filtering** comparisons, which return an *empty vector*
when the system is healthy. Combined with the `noDataState: Alerting` set on them
to fix the 2026-07-30 outage, every healthy evaluation was a NoData evaluation
and therefore a page. Both are now written so the expression **always yields a
number while the metric exists**:

- `avslotargetdrop`: `sum(...) < bool (0.90 * avg_over_time(sum(...)[1d:10m]))` —
  `bool` makes it 0/1 instead of empty/value.
- `avslok8sblindshard`: `max_over_time(...) - count(...)` — a subtraction, whose
  value is now the **number of missing shards** (0 = healthy).

With those, NoData once again means only what `Alerting` is supposed to catch:
the metric stopped being published at all. **If you add a rule with
`noDataState: Alerting`, its expression must never be a bare filtering
comparison.** Use `bool`, or arithmetic, or the Grafana threshold evaluator on a
raw value (as `avslofleetempty` does).

### Why `for` is `0s` on every non-critical tier rule

The group `interval` is `300`, so `for: 10m` needs the alert condition to hold
across **three consecutive** evaluations. A tier that publishes once per cycle
has a live series for only ~5 minutes, i.e. **one** evaluation. Any pending
period above `0s` on a high/medium/low rule can never be satisfied and the rule
would silently never fire. Only the critical tier (`*/5`, continuously fresh)
keeps `for: 5m` / `for: 10m`.

Corollary: this is why the fleet-shaped rules (`avslotargetdrop`,
`avslofleetempty`) are scoped to `tier=~"critical|"` rather than grouped by tier.
All four tiers sweep the *same* fleet, so one continuously-fresh tier observes it
completely, and the critical tier is the only one whose sample is always current.

### Why an untiered `sum()` over these metrics is actively broken after the split

Because of the same ~5-minute staleness, `sum(avtools_snmp_devices_targeted)`
without a tier scope oscillates between ~1375 (critical alone), ~2750 (critical
plus one other) and briefly ~5500, while a trailing-day average settles around
~1966. `avslotargetdrop`'s `< 0.9 x avg` test would then be true at essentially
every evaluation — a permanent page. Never sum a `Priority.ALWAYS` guardrail
across tiers.

### Per-tier windows and thresholds, and where the numbers come from

Freshness windows = **2 missed cycles + a margin for that tier's sweep and
schedule jitter**. Reusing the critical tier's 10m window on an hourly tier would
be true for ~50 minutes of every hour.

| rule | tier | window | derivation |
|---|---|---|---|
| `avslosnmpfresh` | critical | `10m` | 2 x 5m (unchanged) |
| `avslosnmpfreshhigh` | high | `35m` | 2 x 15m + 5m |
| `avslosnmpfreshmedium` | medium | `2h15m` | 2 x 1h + 15m |
| `avslosnmpfreshlow` | low | `12h30m` | 2 x 6h + 30m |

Sweep budgets = **halfway between that tier's projected sweep and its pod's
`activeDeadlineSeconds`** — high enough above normal not to be noise, far enough
below the kill to be a leading indicator rather than a post-mortem.

| rule | tier | sweep | deadline | budget |
|---|---|---|---|---|
| `avslok8ssweepbudget` | critical | ~40s | 150 | **100s** |
| `avslok8ssweepbudgethigh` | high | ~80s | 220 | **150s** |
| `avslok8ssweepbudgetmedium` | medium | ~160s | 320 | **240s** |
| `avslok8ssweepbudgetlow` | low | ~320s | 1200 | **760s** |

The old single global `200s` was wrong twice: an untiered `max()` takes the
slowest tier, so the low tier would trip it every 6 hours; and 200s is *above*
the critical tier's own 150s `activeDeadlineSeconds`, so for critical the rule
was already dead code — the pod is killed at 150s and can never publish a 200s
duration.

Shard-skew thresholds are a function of **shard count, not cadence**: `max/avg`
is bounded above by the number of shards, so the legacy `2.0` is meaningful at 8
shards, weak at 4, and *mathematically unreachable* at 2 (a 2-shard tier can only
reach 2.0 if one shard reports 0). Each threshold is calibrated to the same
physical meaning the original carried — one hot shard running roughly **2.3x**
the others.

| rule | tiers | shards | threshold |
|---|---|---|---|
| `avslok8sshardskew` | critical | 8 | **2.0** (unchanged) |
| `avslok8sshardskewhighmed` | high, medium | 4 | **1.75** |
| `avslok8sshardskewlow` | low | 2 | **1.4** |

### One rule `by (tier)` vs one rule per tier

- **`by (tier)`** where the logic is cadence-independent and the threshold is
  shared: `avslocoverage{warn,crit}` (a ratio has no window), plus
  `avslok8sblindshardslow` and `avslok8sshardskewhighmed` where the grouped tiers
  share a shard count. One rule to maintain, one alert instance per tier.
  Multi-instance rules add **`tier` to `notification_settings.group_by`** so a
  degraded medium tier is not folded into the critical tier's notification and
  swallowed by the `168h` repeat interval.
- **One rule per tier** wherever the *window* or the *threshold* is derived from
  that tier's cadence, sweep time or shard count — freshness and sweep budget.
  A single rule cannot carry four windows.

### Not affected by tiering

`avsloeamfresh` and `avslolandbfresh` are emitted by `run-eam` / `run-landb`,
which take no `--priority` argument and never carry a `tier` label. Left byte-for
-byte unchanged. Confirm on the live stack that `avtools_eam_last_run_timestamp`
and `avtools_landb_last_run_timestamp` really do come back with no `tier` label
after the split.

### Known pre-existing defects, deliberately NOT changed here

- **`{{ $values.C.Value }}` renders empty in every rule in both groups.**
  `$values` is keyed by refId, and these rules' refIds are `#Coverage`,
  `#BlindShard`, ... — there is no `C`. (The `conditions[].query.params: ["C"]`
  field is vestigial; the threshold node uses `expression`.) The phrasing is kept
  verbatim in the new rules for consistency; fixing it means either renaming the
  refIds or writing `{{ (index $values "#BlindShard").Value }}` across all rules,
  which is a separate change.
- **`scripts/patch_grafana_rulegroup.py` rewrites `__dashboardUid__` to
  `av_devices_dashboard`.** Every rule in these two groups annotates
  `av_rooms_dashboard`, so the PROD render is not a no-op for them and
  `prod(source) == source` does not hold here (it still round-trips:
  `prod(qa(x)) == prod(x)`). Pre-existing on `master`; the new rules inherit
  exactly the same behaviour as their siblings.
