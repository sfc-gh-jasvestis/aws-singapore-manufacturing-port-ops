-- Fresh isolated setup only. The guarded runner supplies DEMO_DB and DEMO_WH.
-- No CREATE OR REPLACE: an existing deployment must never be overwritten.
CREATE DATABASE IDENTIFIER($DEMO_DB)
  COMMENT = 'Synthetic Singapore container port operations demo; on-demand';
USE DATABASE IDENTIFIER($DEMO_DB);
CREATE SCHEMA RAW;
CREATE SCHEMA CURATED;
CREATE SCHEMA ML;
CREATE SCHEMA APP;
USE WAREHOUSE IDENTIFIER($DEMO_WH);
USE SCHEMA RAW;
