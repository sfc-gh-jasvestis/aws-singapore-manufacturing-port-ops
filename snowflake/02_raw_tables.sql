-- Synthetic berth-day observations for fictional container terminals that serve a Singapore
-- manufacturing export network. Nothing is seeded as a prediction. Randomness is
-- HASH-seeded, so every rebuild is reproducible: per-berth capacity, crane age and
-- disruption propensity, box moves from weekly seasonality and a pre-holiday export
-- peak, crane wear between preventive-maintenance (PM) visits, berth-type-weighted
-- disruption causes, and two port-wide events.
USE DATABASE IDENTIFIER($DEMO_DB);
USE SCHEMA RAW;
USE WAREHOUSE IDENTIFIER($DEMO_WH);

CREATE TABLE RAW.BERTHS AS
WITH berths AS (
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS BERTH_INDEX
  FROM TABLE(GENERATOR(ROWCOUNT => 30))
), draws AS (
  SELECT BERTH_INDEX,
         MOD(ABS(HASH(BERTH_INDEX, 'sg-portops-age')), 1000000) / 1e6 AS U_AGE,
         MOD(ABS(HASH(BERTH_INDEX, 'sg-portops-rate')), 1000000) / 1e6 AS U_RATE,
         MOD(ABS(HASH(BERTH_INDEX, 'sg-portops-pm')), 1000000) / 1e6 AS U_PM,
         MOD(ABS(HASH(BERTH_INDEX, 'sg-portops-discipline')), 1000000) / 1e6 AS U_DISCIPLINE,
         MOD(ABS(HASH(BERTH_INDEX, 'sg-portops-capacity')), 1000000) / 1e6 AS U_CAPACITY
  FROM berths
)
SELECT 'BT-' || LPAD(BERTH_INDEX::VARCHAR, 4, '0') AS ID,
       'Synthetic berth ' || LPAD(BERTH_INDEX::VARCHAR, 4, '0') AS NAME,
       -- Deterministic spread (6 and 5 are coprime): every port and berth type is present.
       CASE MOD(BERTH_INDEX, 6) WHEN 0 THEN 'Tuas' WHEN 1 THEN 'Pasir Panjang'
            WHEN 2 THEN 'Tanjong Pagar' WHEN 3 THEN 'Pioneer' WHEN 4 THEN 'Sembawang'
            ELSE 'Changi' END AS REGION,
       CASE MOD(BERTH_INDEX, 5) WHEN 0 THEN 'Mainline Berth' WHEN 1 THEN 'Feeder Berth'
            WHEN 2 THEN 'Transshipment Berth' WHEN 3 THEN 'Barge Berth' ELSE 'Reefer Berth' END AS CATEGORY,
       BERTH_INDEX,
       ROUND(2 + U_AGE * 18, 1) AS AGE_YEARS,
       -- Base daily disruption probability 0.6%-3.4%; ~12% of berths are chronic (x3).
       (0.006 + U_RATE * 0.028) * IFF(U_RATE > 0.88, 3, 1) AS BASE_DISRUPTION_RATE,
       7 * (1 + FLOOR(U_PM * 3)) AS PM_INTERVAL_DAYS,
       0.6 + U_DISCIPLINE * 0.38 AS PM_COMPLETION_PROB,
       ROUND(CASE MOD(BERTH_INDEX, 5) WHEN 0 THEN 2400 WHEN 1 THEN 900 WHEN 2 THEN 3100
                  WHEN 3 THEN 450 ELSE 1300 END * (0.8 + U_CAPACITY * 0.4)) AS DAILY_CAPACITY,
       'Active' AS STATUS
FROM draws;

CREATE TABLE RAW.BERTH_DAILY AS
WITH days AS (
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS DAY_INDEX
  FROM TABLE(GENERATOR(ROWCOUNT => 90))
), regional_events AS (
  -- Two port-wide events in the window.
  SELECT * FROM VALUES (31, 'Tuas', 'Sumatra squall stoppage', 10.0),
                       (64, 'Pasir Panjang', 'Terminal operating system outage', 6.0)
    AS o(DAY_INDEX, REGION, EVENT_CAUSE, HOURS)
), base AS (
  SELECT h.ID AS ENTITY_ID, h.BERTH_INDEX, h.CATEGORY, h.REGION, h.AGE_YEARS,
         h.BASE_DISRUPTION_RATE, h.PM_INTERVAL_DAYS, h.PM_COMPLETION_PROB, h.DAILY_CAPACITY,
         d.DAY_INDEX,
         DATEADD('day', d.DAY_INDEX - 89, CURRENT_DATE()) AS EVENT_DATE,
         24.0 AS PLANNED_HOURS,
         MOD(d.DAY_INDEX + h.BERTH_INDEX * 5, h.PM_INTERVAL_DAYS) AS DAYS_SINCE_PM,
         MOD(ABS(HASH(h.ID, d.DAY_INDEX, 'sg-portops-dis')), 1000000) / 1e6 AS U_DIS,
         MOD(ABS(HASH(h.ID, d.DAY_INDEX, 'sg-portops-down')), 1000000) / 1e6 + 1e-6 AS U_DOWN,
         MOD(ABS(HASH(h.ID, d.DAY_INDEX, 'sg-portops-cause')), 1000000) / 1e6 AS U_CAUSE,
         MOD(ABS(HASH(h.ID, d.DAY_INDEX, 'sg-portops-pmdone')), 1000000) / 1e6 AS U_PMDONE,
         MOD(ABS(HASH(h.ID, d.DAY_INDEX, 'sg-portops-volume')), 1000000) / 1e6 AS U_VOLUME,
         MOD(ABS(HASH(h.ID, d.DAY_INDEX, 'sg-portops-noise')), 1000000) / 1e6 AS U_NOISE,
         MOD(ABS(HASH(h.ID, d.DAY_INDEX, 'sg-portops-hit')), 1000000) / 1e6 AS U_HIT,
         e.EVENT_CAUSE, e.HOURS AS EVENT_HOURS
  FROM RAW.BERTHS h CROSS JOIN days d
  LEFT JOIN regional_events e ON e.DAY_INDEX = d.DAY_INDEX AND e.REGION = h.REGION
), loaded AS (
  SELECT *,
         IFF(DAYS_SINCE_PM = 0, 1, 0) AS PM_DUE,
         IFF(DAYS_SINCE_PM = 0 AND U_PMDONE < PM_COMPLETION_PROB, 1, 0) AS PM_COMPLETED,
         -- Quay crane wear rises between PM visits; weak PM discipline carries wear over.
         DAYS_SINCE_PM / PM_INTERVAL_DAYS + (1 - PM_COMPLETION_PROB) AS WEAR,
         -- Bunching episode: 7 of every 22 days per berth (staggered), when late vessels arrive together.
         IFF(MOD(DAY_INDEX + BERTH_INDEX * 3, 22) < 7, 1, 0) AS STRESS,
         -- Box moves: weekly low day and a pre-holiday export peak on day 47 (+48%) easing over 3 days.
         ROUND(DAILY_CAPACITY * (0.66 + 0.29 * U_VOLUME)
               * IFF(MOD(DAY_INDEX, 7) = 5, 0.74, 1.0)
               * CASE DAY_INDEX - 47 WHEN 0 THEN 1.48 WHEN 1 THEN 1.30 WHEN 2 THEN 1.12 ELSE 1.0 END) AS BOX_MOVES
  FROM base
), disruptions AS (
  SELECT *, BOX_MOVES / DAILY_CAPACITY AS LOAD_RATIO,
         LEAST(0.5, BASE_DISRUPTION_RATE * (0.45 + 1.5 * WEAR) * (0.35 + BOX_MOVES / DAILY_CAPACITY)
                    * (1 + AGE_YEARS / 30) * (1 + 2.2 * STRESS)) AS P_DIS
  FROM loaded
), counted AS (
  SELECT *,
         CASE WHEN EVENT_HOURS IS NOT NULL THEN 1
              WHEN U_DIS < P_DIS / 4 THEN 2
              WHEN U_DIS < P_DIS THEN 1
              ELSE 0 END AS DISRUPTION_COUNT
  FROM disruptions
), timed AS (
  SELECT *,
         -- Berth downtime: exponential, mean depends on berth type.
         CASE WHEN DISRUPTION_COUNT = 0 THEN 0.0
              WHEN EVENT_HOURS IS NOT NULL THEN EVENT_HOURS
              ELSE LEAST(18.0, ROUND(DISRUPTION_COUNT * (0.6 - LN(U_DOWN) *
                   CASE CATEGORY WHEN 'Mainline Berth' THEN 3.2 WHEN 'Feeder Berth' THEN 1.9
                                 WHEN 'Transshipment Berth' THEN 3.6 WHEN 'Barge Berth' THEN 1.4 ELSE 2.4 END), 1))
         END AS DOWNTIME_HOURS,
         -- On-time rate (box moves completed inside the vessel's agreed berth window): base by
         -- berth type, minus wear and overload, minus the disruption hit.
         LEAST(0.995, GREATEST(0.50,
           CASE CATEGORY WHEN 'Mainline Berth' THEN 0.935 WHEN 'Feeder Berth' THEN 0.955
                         WHEN 'Transshipment Berth' THEN 0.920 WHEN 'Barge Berth' THEN 0.960 ELSE 0.945 END
           - 0.035 * WEAR - 0.06 * GREATEST(0, LOAD_RATIO - 0.88) - 0.009 * U_NOISE
           - DISRUPTION_COUNT * (0.06 + 0.14 * U_HIT))) AS ON_TIME_RATE
  FROM counted
)
SELECT ENTITY_ID || '-' || TO_CHAR(EVENT_DATE, 'YYYYMMDD') AS EVENT_ID,
       ENTITY_ID, EVENT_DATE, PLANNED_HOURS, DOWNTIME_HOURS,
       PLANNED_HOURS - DOWNTIME_HOURS AS OPERATING_HOURS,
       DISRUPTION_COUNT,
       CASE WHEN DISRUPTION_COUNT = 0 THEN 'None'
            WHEN EVENT_CAUSE IS NOT NULL THEN EVENT_CAUSE
            WHEN CATEGORY = 'Mainline Berth' THEN IFF(U_CAUSE < 0.45, 'Quay crane spreader fault', IFF(U_CAUSE < 0.75, 'Late vessel arrival', 'Stowage plan error'))
            WHEN CATEGORY = 'Feeder Berth' THEN IFF(U_CAUSE < 0.5, 'Mobile harbour crane fault', IFF(U_CAUSE < 0.8, 'Gang shortfall', 'Harbour tug delay'))
            WHEN CATEGORY = 'Transshipment Berth' THEN IFF(U_CAUSE < 0.55, 'Connecting vessel delay', 'Quay crane hoist fault')
            WHEN CATEGORY = 'Barge Berth' THEN IFF(U_CAUSE < 0.6, 'Tidal window miss', 'Mooring line failure')
            ELSE IFF(U_CAUSE < 0.55, 'Reefer plug fault', 'Customs inspection hold') END AS ROOT_CAUSE,
       PM_DUE, PM_COMPLETED,
       BOX_MOVES,
       FLOOR(BOX_MOVES * ON_TIME_RATE) AS ON_TIME_MOVES,
       ROUND(BOX_MOVES * (1.6 + U_VOLUME * 0.9)) AS YARD_MOVES,
       ROUND(BOX_MOVES * (1.6 + U_VOLUME * 0.9) * (0.010 + 0.008 * WEAR + 0.019 * DISRUPTION_COUNT + 0.006 * U_NOISE)) AS REHANDLE_MOVES,
       ROUND(3.5 + 3.4 * WEAR + 5.0 * GREATEST(0, LOAD_RATIO - 0.8) + 2.6 * STRESS + 4.0 * DISRUPTION_COUNT + U_NOISE * 1.3, 2) AS VESSEL_WAIT_HOURS,
       ROUND(LEAST(100, 100 * LOAD_RATIO * (0.82 + 0.12 * U_NOISE) + 7 * STRESS + 4 * DISRUPTION_COUNT), 1) AS BERTH_OCCUPANCY_PCT,
       ROUND(86.0 + 12.0 * ON_TIME_RATE + 1.4 * U_NOISE, 1) AS SCHEDULE_ADHERENCE_PCT,
       CURRENT_TIMESTAMP() AS LOADED_AT
FROM timed;

-- Quay crane readiness per berth (snapshot): cranes required versus serviceable on hand.
CREATE TABLE RAW.EQUIPMENT_READINESS AS
SELECT ID AS ENTITY_ID,
       CASE CATEGORY WHEN 'Mainline Berth' THEN 'Ship-to-shore crane' WHEN 'Feeder Berth' THEN 'Mobile harbour crane'
                     WHEN 'Transshipment Berth' THEN 'Tandem-lift STS crane' WHEN 'Barge Berth' THEN 'Barge crane'
                     ELSE 'Reefer monitoring rack' END AS EQUIPMENT_TYPE,
       3 + MOD(ABS(HASH(ID, 'sg-portops-req')), 9) AS REQUIRED_QTY,
       FLOOR((3 + MOD(ABS(HASH(ID, 'sg-portops-req')), 9)) * (0.70 + MOD(ABS(HASH(ID, 'sg-portops-avail')), 1000) / 1000 * 0.36)) AS ON_HAND_QTY,
       MOD(ABS(HASH(ID, 'sg-portops-order')), 3) AS ON_ORDER_QTY,
       CURRENT_DATE() AS SNAPSHOT_DATE
FROM RAW.BERTHS;
