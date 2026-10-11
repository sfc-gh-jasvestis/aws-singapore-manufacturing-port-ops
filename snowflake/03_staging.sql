-- Validate the producer contract before building downstream objects.
USE DATABASE IDENTIFIER($DEMO_DB);
USE SCHEMA RAW;
USE WAREHOUSE IDENTIFIER($DEMO_WH);

EXECUTE IMMEDIATE $$
DECLARE
  violations INTEGER;
  invalid_source EXCEPTION (-20001, 'Synthetic source failed grain or measure validation');
BEGIN
  SELECT COUNT(*) INTO :violations FROM (
    SELECT ENTITY_ID, EVENT_DATE
    FROM RAW.BERTH_DAILY
    GROUP BY ENTITY_ID, EVENT_DATE HAVING COUNT(*) <> 1
    UNION ALL
    SELECT observation.ENTITY_ID, observation.EVENT_DATE
    FROM RAW.BERTH_DAILY observation
    LEFT JOIN RAW.BERTHS berth ON berth.ID = observation.ENTITY_ID
    WHERE berth.ID IS NULL OR observation.PLANNED_HOURS <= 0
       OR observation.OPERATING_HOURS < 0 OR observation.DOWNTIME_HOURS < 0
       OR observation.OPERATING_HOURS + observation.DOWNTIME_HOURS <> observation.PLANNED_HOURS
       OR observation.ON_TIME_MOVES < 0 OR observation.ON_TIME_MOVES > observation.BOX_MOVES
       OR observation.YARD_MOVES < 0 OR observation.REHANDLE_MOVES < 0
       OR observation.PM_COMPLETED > observation.PM_DUE
  );
  IF (violations > 0) THEN
    RAISE invalid_source;
  END IF;
END;
$$;
