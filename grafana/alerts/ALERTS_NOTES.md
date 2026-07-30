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
