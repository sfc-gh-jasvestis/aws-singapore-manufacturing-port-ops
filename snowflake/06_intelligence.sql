-- ============================================================================
-- 06_INTELLIGENCE.SQL - search, anomaly detection, semantic view, agent,
-- live-telemetry alert and on-demand refresh DAG.
-- Run with snowflake/run_intelligence.py (substitutes checked __DEMO_DB__ /
-- __DEMO_WH__ / __ALERT_EMAIL__). Requires 00-05, plus 08 (Snowflake only) or
-- aws/setup_aws.py (AWS build) for RAW.LIVE_TELEMETRY.
-- Alerts and tasks are created SUSPENDED; run them with EXECUTE ALERT / EXECUTE TASK.
-- ============================================================================
USE DATABASE __DEMO_DB__;
CREATE SCHEMA IF NOT EXISTS SEARCH;
CREATE SCHEMA IF NOT EXISTS APP;

-- ---------- Synthetic berth-operations knowledge base (clearly synthetic SOPs) ----------
CREATE OR REPLACE TABLE SEARCH.BERTH_SOP_DOCS AS
WITH causes AS (
  SELECT DISTINCT r.ROOT_CAUSE, h.CATEGORY
  FROM RAW.BERTH_DAILY r JOIN RAW.BERTHS h ON h.ID = r.ENTITY_ID
  WHERE r.ROOT_CAUSE IS NOT NULL AND r.DISRUPTION_COUNT > 0
)
SELECT
  'SOP-' || LPAD(ROW_NUMBER() OVER (ORDER BY CATEGORY, ROOT_CAUSE)::VARCHAR, 3, '0') AS DOC_ID,
  'SOP' AS DOC_TYPE,
  CATEGORY,
  ROOT_CAUSE,
  CATEGORY || ' - ' || ROOT_CAUSE || ' disruption response' AS TITLE,
  'Synthetic demo SOP. Berth type: ' || CATEGORY || '. Disruption cause: ' || ROOT_CAUSE || '. '
  || 'Step 1: notify the berth duty manager and the vessel planner, record the vessel call and affected container IDs, and warn the yard and gate teams. '
  || 'Step 2: ' || CASE
       WHEN ROOT_CAUSE ILIKE '%crane%' OR ROOT_CAUSE ILIKE '%spreader%' OR ROOT_CAUSE ILIKE '%hoist%' THEN 'move the gang to a standby crane from the readiness pool, lock out the faulty crane for inspection and resequence the discharge and load plan.'
       WHEN ROOT_CAUSE ILIKE '%squall%' OR ROOT_CAUSE ILIKE '%tidal%' OR ROOT_CAUSE ILIKE '%mooring%' THEN 'stop crane work under the wind or tide limits, secure the vessel and cranes, and publish revised berthing times to lines and shippers.'
       WHEN ROOT_CAUSE ILIKE '%customs%' OR ROOT_CAUSE ILIKE '%operating system%' THEN 'switch to the manual job-list fallback, prioritise time-critical export boxes for the plants and reconcile every move once the system is back.'
       WHEN ROOT_CAUSE ILIKE '%arrival%' OR ROOT_CAUSE ILIKE '%connecting%' OR ROOT_CAUSE ILIKE '%tug%' THEN 'reallocate the berth window, call the next vessel forward if ready, and hold export boxes in the yard for the delayed call.'
       WHEN ROOT_CAUSE ILIKE '%gang%' OR ROOT_CAUSE ILIKE '%stowage%' THEN 'call the relief gang or ask the line planner for a corrected stowage plan, then resequence the crane split.'
       WHEN ROOT_CAUSE ILIKE '%reefer%' THEN 'move affected reefers to spare plug points, log temperatures every 30 minutes and notify the shipper.'
       ELSE 'record the issue, contain affected boxes and escalate to the terminal operations lead.'
     END
  || ' Step 3: if vessel waiting time exceeds 12 hours or berth occupancy exceeds 92% after recovery, keep the berth on the watch list and offer later windows to new calls. '
  || 'Step 4: confirm recovery of the on-time move rate and record the root cause and container IDs in the disruption log.' AS CONTENT
FROM causes;

CREATE OR REPLACE CORTEX SEARCH SERVICE SEARCH.BERTH_SOP_SEARCH
  ON CONTENT
  ATTRIBUTES CATEGORY, ROOT_CAUSE
  WAREHOUSE = __DEMO_WH__
  TARGET_LAG = '7 days'
AS (SELECT DOC_ID, TITLE, CATEGORY, ROOT_CAUSE, CONTENT FROM SEARCH.BERTH_SOP_DOCS);

-- ---------- Vessel waiting-time anomaly detection (train first 75 days, detect last 15) ----------
CREATE OR REPLACE VIEW ML.WAIT_SERIES AS
SELECT ENTITY_ID, EVENT_DATE::TIMESTAMP_NTZ AS TS, VESSEL_WAIT_HOURS::FLOAT AS WAIT_HOURS
FROM RAW.BERTH_DAILY;
CREATE OR REPLACE VIEW ML.WAIT_TRAIN AS
SELECT * FROM ML.WAIT_SERIES WHERE TS < (SELECT DATEADD(day, -15, MAX(TS)) FROM ML.WAIT_SERIES);
CREATE OR REPLACE VIEW ML.WAIT_DETECT AS
SELECT * FROM ML.WAIT_SERIES WHERE TS >= (SELECT DATEADD(day, -15, MAX(TS)) FROM ML.WAIT_SERIES);

CREATE OR REPLACE SNOWFLAKE.ML.ANOMALY_DETECTION ML.WAIT_ANOMALY_MODEL(
  INPUT_DATA => SYSTEM$REFERENCE('VIEW', 'ML.WAIT_TRAIN'),
  SERIES_COLNAME => 'ENTITY_ID', TIMESTAMP_COLNAME => 'TS', TARGET_COLNAME => 'WAIT_HOURS',
  LABEL_COLNAME => '');

CREATE OR REPLACE TABLE ML.WAIT_ANOMALIES AS
SELECT SERIES::VARCHAR AS ENTITY_ID, TS::DATE AS EVENT_DATE, Y AS WAIT_HOURS, FORECAST AS EXPECTED,
       LOWER_BOUND, UPPER_BOUND, IS_ANOMALY, PERCENTILE
FROM TABLE(ML.WAIT_ANOMALY_MODEL!DETECT_ANOMALIES(
  INPUT_DATA => SYSTEM$REFERENCE('VIEW', 'ML.WAIT_DETECT'),
  SERIES_COLNAME => 'ENTITY_ID', TIMESTAMP_COLNAME => 'TS', TARGET_COLNAME => 'WAIT_HOURS'));

-- ---------- Semantic view ----------
CREATE OR REPLACE SEMANTIC VIEW APP.PORT_OPS_ANALYTICS
  TABLES (
    berths AS CURATED.PERFORMANCE_SUMMARY PRIMARY KEY (ENTITY_ID)
      WITH SYNONYMS = ('entities', 'berths', 'quays', 'berth positions')
      COMMENT = 'One row per container berth (entity), 90-day totals',
    risk AS ML.DISRUPTION_RISK_SCORES PRIMARY KEY (ENTITY_ID)
      COMMENT = 'Latest next-7-day berth disruption probability per berth',
    causes AS CURATED.DISRUPTION_CAUSES PRIMARY KEY (ROOT_CAUSE)
      COMMENT = 'Berth disruptions by root cause, 90 days',
    daily AS CURATED.TREND_ANALYSIS PRIMARY KEY (METRIC_DATE)
      COMMENT = 'Port-network totals per day'
  )
  RELATIONSHIPS (risk_berth AS risk (ENTITY_ID) REFERENCES berths)
  FACTS (
    berths.on_time_f AS ON_TIME_MOVES,
    berths.box_moves_f AS BOX_MOVES,
    berths.moves_f AS YARD_MOVES,
    berths.rehandles_f AS REHANDLE_MOVES,
    berths.disruptions_f AS DISRUPTION_COUNT,
    berths.downtime_hours_f AS DOWNTIME_HOURS,
    berths.operating_hours_f AS OPERATING_HOURS,
    berths.planned_hours_f AS PLANNED_HOURS,
    risk.disruption_prob_f AS DISRUPTION_PROB_7D,
    causes.cause_disruptions_f AS DISRUPTION_COUNT,
    causes.cause_late_f AS LATE_MOVES,
    causes.cause_hours_f AS DOWNTIME_HOURS,
    daily.day_on_time_f AS ON_TIME_MOVES,
    daily.day_moves_f AS BOX_MOVES,
    daily.day_disruptions_f AS DISRUPTION_COUNT
  )
  DIMENSIONS (
    berths.berth_id AS ENTITY_ID WITH SYNONYMS = ('berth', 'entity', 'entity id', 'berth code'),
    berths.berth_name AS ENTITY_NAME,
    berths.region AS REGION WITH SYNONYMS = ('region', 'port district', 'district', 'area') COMMENT = 'Singapore port district',
    berths.berth_type AS CATEGORY WITH SYNONYMS = ('berth type', 'service type', 'category'),
    risk.risk_band AS RISK_BAND COMMENT = 'High >= 0.5, Medium >= 0.25, else Low',
    risk.scored_as_of AS SCORED_AS_OF,
    causes.root_cause AS ROOT_CAUSE,
    daily.metric_date AS METRIC_DATE
  )
  METRICS (
    berths.berth_count AS COUNT(berths.berth_id) WITH SYNONYMS = ('number of entities', 'entity count', 'number of berths'),
    berths.on_time_move_pct AS 100 * SUM(berths.on_time_f) / NULLIF(SUM(berths.box_moves_f), 0)
      WITH SYNONYMS = ('on-time rate', 'berth window performance') COMMENT = 'Box moves completed inside the berth window / box moves',
    berths.total_disruptions AS SUM(berths.disruptions_f) WITH SYNONYMS = ('disruptions', 'berth disruptions', 'stoppages'),
    berths.rehandle_moves_per_1k AS 1000 * SUM(berths.rehandles_f) / NULLIF(SUM(berths.moves_f), 0),
    berths.total_box_moves AS SUM(berths.box_moves_f) WITH SYNONYMS = ('box moves', 'container moves', 'quay moves'),
    berths.total_yard_moves AS SUM(berths.moves_f),
    berths.crane_uptime_pct AS 100 * SUM(berths.operating_hours_f) / NULLIF(SUM(berths.planned_hours_f), 0),
    berths.total_downtime_hours AS SUM(berths.downtime_hours_f),
    risk.avg_disruption_prob AS AVG(risk.disruption_prob_f),
    causes.cause_disruptions AS SUM(causes.cause_disruptions_f),
    causes.cause_late_moves AS SUM(causes.cause_late_f),
    causes.cause_downtime_hours AS SUM(causes.cause_hours_f),
    daily.daily_on_time_pct AS 100 * SUM(daily.day_on_time_f) / NULLIF(SUM(daily.day_moves_f), 0),
    daily.daily_box_moves AS SUM(daily.day_moves_f),
    daily.daily_disruptions AS SUM(daily.day_disruptions_f)
  )
  COMMENT = 'Synthetic Singapore container port operations analytics (demo)';

-- ---------- Cortex Agent ----------
CREATE OR REPLACE AGENT APP.PORT_OPS_AGENT
  COMMENT = 'Berth operations assistant over synthetic Singapore container terminals'
  FROM SPECIFICATION
$$
models:
  orchestration: claude-sonnet-4-5
instructions:
  response: "Answer only from tool results. State that data is synthetic. Give berth IDs and numbers with units."
  orchestration: "Use port_ops_analyst for on-time box moves, berth disruptions, rehandles, box-move volume, crane uptime, berths, port districts, risk and root causes. Use sop_search for disruption response procedures."
tools:
  - tool_spec:
      type: cortex_analyst_text_to_sql
      name: port_ops_analyst
      description: "On-time box moves, berth disruptions, rehandle moves per 1,000 yard moves, box-move volume, crane uptime, root causes and disruption-risk scores per berth"
  - tool_spec:
      type: cortex_search
      name: sop_search
      description: "Synthetic disruption-response SOPs by berth type and cause"
tool_resources:
  port_ops_analyst:
    semantic_view: __DEMO_DB__.APP.PORT_OPS_ANALYTICS
    execution_environment:
      type: warehouse
      warehouse: __DEMO_WH__
  sop_search:
    name: __DEMO_DB__.SEARCH.BERTH_SOP_SEARCH
    max_results: 3
    id_column: DOC_ID
    title_column: TITLE
$$;

-- ---------- Live-telemetry alert ----------
CREATE TABLE IF NOT EXISTS APP.ALERT_LOG (
  ALERTED_AT TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(), BERTH_ID VARCHAR,
  EVENT_TS TIMESTAMP_NTZ, VESSEL_WAIT_HOURS FLOAT, BERTH_OCCUPANCY_PCT FLOAT, SOP_HINT VARCHAR);

CREATE OR REPLACE NOTIFICATION INTEGRATION SG_MANUFACTURING_PORT_OPS_EMAIL_INT
  TYPE = EMAIL ENABLED = TRUE ALLOWED_RECIPIENTS = ('__ALERT_EMAIL__');

CREATE OR REPLACE PROCEDURE APP.LOG_LIVE_ALARMS()
RETURNS NUMBER
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  n NUMBER;
BEGIN
  INSERT INTO APP.ALERT_LOG (BERTH_ID, EVENT_TS, VESSEL_WAIT_HOURS, BERTH_OCCUPANCY_PCT, SOP_HINT)
    SELECT t.BERTH_ID, t.EVENT_TS, t.VESSEL_WAIT_HOURS, t.BERTH_OCCUPANCY_PCT,
           'Check ' || h.CATEGORY || ' SOPs; current risk band ' || COALESCE(r.RISK_BAND, 'n/a')
    FROM RAW.LIVE_TELEMETRY t
    JOIN RAW.BERTHS h ON h.ID = t.BERTH_ID
    LEFT JOIN ML.DISRUPTION_RISK_SCORES r ON r.ENTITY_ID = t.BERTH_ID
    WHERE t.STATUS = 'ALARM'
      AND NOT EXISTS (SELECT 1 FROM APP.ALERT_LOG l WHERE l.BERTH_ID = t.BERTH_ID AND l.EVENT_TS = t.EVENT_TS);
  n := SQLROWCOUNT;
  IF (n > 0) THEN
    CALL SYSTEM$SEND_EMAIL('SG_MANUFACTURING_PORT_OPS_EMAIL_INT', '__ALERT_EMAIL__',
      '[Demo] Singapore berth telemetry alarm',
      'New live-telemetry alarms logged in APP.ALERT_LOG: ' || :n || '. Data is synthetic.');
  END IF;
  RETURN n;
END;
$$;

CREATE OR REPLACE ALERT APP.LIVE_ALARM_ALERT
  WAREHOUSE = __DEMO_WH__
  SCHEDULE = '5 MINUTE'
  IF (EXISTS (
    SELECT 1 FROM RAW.LIVE_TELEMETRY t
    WHERE t.STATUS = 'ALARM'
      AND NOT EXISTS (SELECT 1 FROM APP.ALERT_LOG l WHERE l.BERTH_ID = t.BERTH_ID AND l.EVENT_TS = t.EVENT_TS)))
  THEN CALL APP.LOG_LIVE_ALARMS();

-- ---------- On-demand refresh DAG (suspended; run with EXECUTE TASK APP.TASK_REFRESH_CURATED) ----------
CREATE OR REPLACE PROCEDURE APP.REFRESH_CURATED()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
  ALTER DYNAMIC TABLE CURATED.PERFORMANCE_SUMMARY REFRESH;
  ALTER DYNAMIC TABLE CURATED.TREND_ANALYSIS REFRESH;
  ALTER DYNAMIC TABLE CURATED.DISRUPTION_CAUSES REFRESH;
  ALTER DYNAMIC TABLE CURATED.KPI_SUMMARY REFRESH;
  RETURN 'refreshed';
END;
$$;

CREATE OR REPLACE TASK APP.TASK_REFRESH_CURATED
  WAREHOUSE = __DEMO_WH__
AS
  CALL APP.REFRESH_CURATED();

CREATE OR REPLACE TASK APP.TASK_RESCORE_RISK
  WAREHOUSE = __DEMO_WH__
  AFTER APP.TASK_REFRESH_CURATED
AS
  CREATE OR REPLACE TABLE ML.DISRUPTION_RISK_SCORES COPY GRANTS AS
  WITH latest AS (
    SELECT * FROM ML.DISRUPTION_FEATURES QUALIFY ROW_NUMBER() OVER (PARTITION BY ENTITY_ID ORDER BY EVENT_DATE DESC) = 1
  ), p AS (
    SELECT ENTITY_ID, EVENT_DATE,
           ML.DISRUPTION_RISK_MODEL!PREDICT(INPUT_DATA => OBJECT_CONSTRUCT(
             'CATEGORY', CATEGORY, 'AGE_YEARS', AGE_YEARS, 'VESSEL_WAIT_HOURS', VESSEL_WAIT_HOURS,
             'BERTH_OCCUPANCY_PCT', BERTH_OCCUPANCY_PCT, 'WAIT_7D', WAIT_7D, 'DISRUPTIONS_30D', DISRUPTIONS_30D)) AS PRED
    FROM latest
  )
  SELECT ENTITY_ID, EVENT_DATE AS SCORED_AS_OF, ROUND(PRED:probability:DISRUPTION::FLOAT, 4) AS DISRUPTION_PROB_7D,
         CASE WHEN PRED:probability:DISRUPTION::FLOAT >= 0.5 THEN 'High'
              WHEN PRED:probability:DISRUPTION::FLOAT >= 0.25 THEN 'Medium' ELSE 'Low' END AS RISK_BAND,
         CURRENT_TIMESTAMP() AS SCORED_AT
  FROM p;
