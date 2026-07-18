# av-tools-grafana

Grafana **dashboards** and **alert rulegroups** for AV Tools — split out of the
`av-tools` application repo so panel changes are cheap to ship.

## Why this repo exists

In `av-tools`, a one-line dashboard tweak had to drag through the whole app
pipeline — koji RPM build, full test suite, integration, e2e (~20 stages, no
`needs:` DAG) — before the light JSON-push could run. Here the pipeline is just
**validate JSON → push to Grafana**: seconds, not ~20 minutes, and decoupled from
app releases (dashboards change far more often).

## Layout

```
grafana/dashboard/{qa,prod}/*.json   dashboards (per environment)
grafana/alerts/*.rulegroup.PUT.json  alert rulegroups
scripts/sync_grafana_*.sh            push scripts (verbatim from av-tools)
```

The content lives under `grafana/` because the sync scripts resolve dashboards at
`../grafana/dashboard/{qa,prod}` relative to `scripts/`.

## Contract with `av-tools`

Loose coupling **by metric name**, not code: the alert rulegroups reference
metrics the app emits (`avtools_*`). If `av-tools` renames or removes a metric,
the matching alert here needs updating. That's the only cross-repo touch, and
it's rare.

## Required CI/CD variables (Settings → CI/CD → Variables, masked)

| Variable | What |
|---|---|
| `GRAFANA_API_TOKEN_QA` | Grafana service-account token, QA folder |
| `GRAFANA_API_TOKEN_PROD` | Grafana service-account token, PROD folder |

## Deploy

- **QA** — push to branch `qa` (or a tag), then run the manual `deploy_qa` job.
- **PROD** — tag a release, then run the manual `deploy_prod` job.

Both are manual gates; nothing deploys automatically.
