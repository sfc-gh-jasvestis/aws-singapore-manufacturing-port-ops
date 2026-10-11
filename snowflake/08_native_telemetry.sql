-- ============================================================================
-- 08_native_telemetry.sql - Snowflake-only build: live telemetry without AWS.
-- Creates RAW.LIVE_TELEMETRY (same columns as the Snowpipe target created by
-- aws/setup_aws.py) and APP.SIMULATE_TELEMETRY(N), which inserts synthetic
-- quay telemetry readings (vessel waiting hours, berth occupancy) with the same value ranges and ~10% ALARM rate as
-- aws/publish_telemetry.py. Rows are inserted directly; this simulates a
-- sensor feed and is not Snowpipe Streaming.
-- Run before 06_intelligence.sql (the alert reads RAW.LIVE_TELEMETRY).
-- Idempotent: safe to run in the AWS build too.
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS RAW;
CREATE SCHEMA IF NOT EXISTS APP;

CREATE TABLE IF NOT EXISTS RAW.LIVE_TELEMETRY (
  BERTH_ID VARCHAR, EVENT_TS TIMESTAMP_NTZ, VESSEL_WAIT_HOURS FLOAT, BERTH_OCCUPANCY_PCT FLOAT,
  STATUS VARCHAR, IOT_RECEIVED_TS TIMESTAMP_NTZ, SOURCE_FILE VARCHAR,
  LOADED_AT TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP());

CREATE OR REPLACE PROCEDURE APP.SIMULATE_TELEMETRY(N NUMBER)
RETURNS NUMBER
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
  IF (N < 1 OR N > 1000) THEN
    RETURN 0;
  END IF;
  INSERT INTO RAW.LIVE_TELEMETRY (BERTH_ID, EVENT_TS, VESSEL_WAIT_HOURS, BERTH_OCCUPANCY_PCT, STATUS, IOT_RECEIVED_TS, SOURCE_FILE)
    WITH g AS (
      SELECT 'BT-' || LPAD(UNIFORM(0, 29, RANDOM())::VARCHAR, 4, '0') AS BERTH_ID,
             UNIFORM(0::FLOAT, 1::FLOAT, RANDOM()) < 0.1 AS IS_ALARM,
             SYSDATE() AS TS, SEQ4() AS I
      FROM TABLE(GENERATOR(ROWCOUNT => 1000))
    )
    -- NORMAL() needs a constant mean, so the alarm offset is added outside it.
    SELECT BERTH_ID, TS,
           ROUND(IFF(IS_ALARM, 15.0, 5.5) + NORMAL(0, 1.4, RANDOM()), 2),
           ROUND(LEAST(100, IFF(IS_ALARM, 95, 71) + NORMAL(0, 3, RANDOM())), 1),
           IFF(IS_ALARM, 'ALARM', 'NORMAL'), TS, 'APP.SIMULATE_TELEMETRY'
    FROM g
    WHERE I < :N;
  RETURN SQLROWCOUNT;
END;
$$;

-- Optional continuous feed for longer demos (suspended; RESUME to start, SUSPEND after).
CREATE OR REPLACE TASK APP.TASK_SIMULATE_TELEMETRY
  WAREHOUSE = __DEMO_WH__
  SCHEDULE = '1 MINUTE'
AS
  CALL APP.SIMULATE_TELEMETRY(5);
