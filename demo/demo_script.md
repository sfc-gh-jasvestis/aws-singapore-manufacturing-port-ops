# Singapore Manufacturing Port Operations Control Tower

**Singapore - Container Terminal Berth Operations**
Use case: On-time box moves, container traceability and berth disruption risk

> Berth monitoring for Meranti Quay Terminals, a fictional Singapore container terminal operator that serves the export network of the fictional manufacturer Halcyon Components: 30 berths across 6 Singapore port districts (mainline, feeder, transshipment, barge and reefer berths), with dynamic tables, a holdout-evaluated disruption-risk classifier, a box-move forecast and grounded AI answers.

## Why Snowflake

- **Dynamic tables** reconcile on-time box moves, rehandle moves and crane uptime from RAW berth data, with checks in `run_core.py`
- **Disruption-risk classification** gives a holdout-evaluated next-7-day disruption probability per berth
- **Box-move forecast** projects 14 days of terminal-wide box moves with prediction intervals
- **Grounded AI**: the Cortex Agent (Analyst over a semantic view, plus Search over SOPs) shows its SQL and SOP citations
- **Live telemetry**: a native simulator (Snowflake only) or IoT Core, S3 and Snowpipe (AWS build), then an alert and email

## What is built

| | |
|---|---|
| Dimension table | `RAW.BERTHS` (30 rows) |
| Fact table | `RAW.BERTH_DAILY` (2,700 berth-days, 90 days) |
| Curated layer | `CURATED.KPI_SUMMARY`, `PERFORMANCE_SUMMARY`, `DISRUPTION_CAUSES`, `TREND_ANALYSIS` |
| ML | `ML.DISRUPTION_RISK_SCORES`, `ML.DISRUPTION_RISK_HOLDOUT_METRICS`, `ML.VOLUME_FORECAST`, `ML.WAIT_ANOMALIES` |

Port districts: Tuas, Pasir Panjang, Tanjong Pagar, Pioneer, Sembawang, Changi.
Berth types: Mainline Berth, Feeder Berth, Transshipment Berth, Barge Berth, Reefer Berth.

## KPI cards (live from `CURATED.KPI_SUMMARY`; no fallback values)

| Card | Value from the seeded data |
|---|---|
| On-Time Box Moves | 88.5% |
| Berth Disruptions | 399 |
| Rehandles per 1k Yard Moves | 21.24 |
| Box Moves Handled | 3,520,096 |
| Crane Uptime | 98.0% |
| Berths Monitored | 30 |
| Crane Readiness | 79.3% |

Values are synthetic. A rebuild reproduces them because the data is HASH-seeded; dates are relative to the build day.

## Demo flow

1. Executive Cockpit (Farah Iskandar): KPIs, daily on-time box moves, late box moves by disruption cause, berth table
2. Predictive (Marcus Seah): holdout metrics, risk bands, 14-day box-move forecast, vessel waiting-time anomalies
3. Berth Health: crane uptime, crane readiness, crane PM compliance against on-time box moves, then generate the action memo
4. Live IoT: run `CALL APP.SIMULATE_TELEMETRY(20)` (Snowflake only) or `python aws/publish_telemetry.py --count 20` (AWS build). Then run `EXECUTE ALERT APP.LIVE_ALARM_ALERT` and show the alert log and email.
5. Ask AI: the Cortex Agent answers metric questions through the semantic view and cites SOPs from Cortex Search. The SQL is shown.
6. QuickSight (AWS build): the same Snowflake tables through DIRECT_QUERY
7. Architecture: both builds side by side

## Talking points

- Per-berth on-time rate ranges from 83.6% to 92.7%. Tanjong Pagar is the lowest port district, at 86.64%, against 89.37% at Changi; the district spread is under three points, so the berth-level view matters more than the district average.
- Connecting vessel delays at transshipment berths make the most box moves late (26,768) of the 14 disruption causes. That fits a hub where most boxes change vessels.
- The risk model is evaluated on a time-based holdout: precision 0.67 and recall 0.60 at 0.5, against a 0.51 base rate. Present it as triage, not a guarantee.
- The Tuas Sumatra squall stoppage and the Pasir Panjang terminal operating system outage are excluded from disruption labels, because they are port-wide events, not berth-driven.
- Container traceability: SOPs require recording the vessel call and affected container IDs, and each berth-day records on-time box moves and schedule adherence.

## Business impact

Use only the sourced references in `README.md` (Business Impact).
