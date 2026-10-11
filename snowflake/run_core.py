"""Fail-fast isolated core setup (00/02/03/04 only), never full-demo certification.

Use an existing extra-small, auto-suspending warehouse. This runner refuses
canonical/live database names, existing databases, wrong accounts, and large
warehouses. It does not train models, activate schedules, or create AWS objects.
"""
import argparse
import io
import json
import re
import time
from pathlib import Path

FILES = ('00_setup.sql', '02_raw_tables.sql', '03_staging.sql', '04_dynamic_tables.sql')
DYNAMIC_TABLES = ('PERFORMANCE_SUMMARY', 'TREND_ANALYSIS', 'DISRUPTION_CAUSES', 'KPI_SUMMARY')


def checked_identifier(value):
    if not re.fullmatch(r'[A-Z][A-Z0-9_]{0,127}', value):
        raise ValueError('Use simple uppercase SQL identifiers')
    return value


def validate_target(database, warehouse):
    checked_identifier(database)
    checked_identifier(warehouse)
    if not database.startswith('SINGAPORE_MANUFACTURING_PORT_OPS_'):
        raise ValueError('Only isolated SINGAPORE_MANUFACTURING_PORT_OPS_ databases are accepted')


def connect(name):
    import os
    import tomllib
    import snowflake.connector
    home = Path(os.environ.get('SNOWFLAKE_HOME', Path.home() / '.snowflake'))
    for filename in ('connections.toml', 'config.toml'):
        path = home / filename
        if path.exists():
            config = tomllib.loads(path.read_text())
            connections = config.get('connections', config)
            if name in connections:
                return snowflake.connector.connect(**connections[name])
    raise RuntimeError('Named local Snowflake connection not found')


def run(connection, database, warehouse, expect_account=None):
    from snowflake.connector.util_text import split_statements
    validate_target(database, warehouse)
    evidence = []
    cursor = connection.cursor()
    created_database = False
    try:
        cursor.execute('SELECT CURRENT_ACCOUNT_NAME(), CURRENT_ACCOUNT(), CURRENT_REGION()')
        identity = cursor.fetchone()
        if expect_account and identity[1] != expect_account.upper():
            raise RuntimeError('Snowflake identity mismatch; no writes attempted')
        cursor.execute('SHOW WAREHOUSES')
        names = [column[0].lower() for column in cursor.description]
        warehouses = [dict(zip(names, row)) for row in cursor.fetchall()]
        selected = next((row for row in warehouses if row['name'] == warehouse), None)
        if not selected or selected['size'] != 'X-Small' or not 1 <= int(selected['auto_suspend']) <= 120:
            raise RuntimeError('Warehouse must exist, be X-Small and auto-suspend within 120 seconds')
        cursor.execute('SHOW DATABASES')
        names = [column[0].lower() for column in cursor.description]
        if any(dict(zip(names, row))['name'] == database for row in cursor.fetchall()):
            raise RuntimeError('Target already exists; choose a new isolated namespace')
        cursor.execute('SET DEMO_DB = %s', (database,))
        cursor.execute('SET DEMO_WH = %s', (warehouse,))
        cursor.execute("ALTER SESSION SET STATEMENT_TIMEOUT_IN_SECONDS = 60, QUERY_TAG = 'sg-manufacturing-port-ops-core'")
        for filename in FILES:
            sql = (Path(__file__).resolve().parent / filename).read_text()
            # DT WAREHOUSE is a DDL property and rejects IDENTIFIER($variable).
            # Only a validated simple identifier is substituted, never free text.
            sql = sql.replace('__DEMO_WH__', warehouse)
            for statement, _ in split_statements(io.StringIO(sql)):
                if not statement.strip():
                    continue
                started = time.monotonic()
                cursor.execute(statement)
                if filename == '00_setup.sql' and 'CREATE DATABASE IDENTIFIER' in statement:
                    created_database = True
                evidence.append({'file': filename, 'query_id': cursor.sfqid,
                                 'seconds': round(time.monotonic() - started, 3)})
        cursor.execute('SELECT COUNT(*) FROM RAW.BERTHS')
        berth_count = cursor.fetchone()[0]
        cursor.execute('SELECT COUNT(*) FROM RAW.BERTH_DAILY')
        observations = cursor.fetchone()[0]
        if (berth_count, observations) != (30, 2700):
            raise RuntimeError('Unexpected synthetic source cardinalities')
        cursor.execute("SELECT TITLE, VALUE_NUM FROM CURATED.KPI_SUMMARY ORDER BY SORT_ORDER")
        metrics = dict(cursor.fetchall())
        # Data is randomised, so reconcile KPIs against independent recomputation from RAW.
        cursor.execute("""SELECT (SELECT COUNT(*) FROM RAW.BERTHS),
            (SELECT ROUND(100.0 * SUM(LEAST(ON_HAND_QTY, REQUIRED_QTY)) / SUM(REQUIRED_QTY), 6) FROM RAW.EQUIPMENT_READINESS),
            (SELECT ROUND(100.0 * SUM(ON_TIME_MOVES) / SUM(BOX_MOVES), 6) FROM RAW.BERTH_DAILY),
            (SELECT ROUND(100.0 * SUM(OPERATING_HOURS) / SUM(PLANNED_HOURS), 6) FROM RAW.BERTH_DAILY),
            (SELECT SUM(DISRUPTION_COUNT) FROM RAW.BERTH_DAILY)""")
        expected = dict(zip(['Berths Monitored', 'Crane Readiness', 'On-Time Box Moves', 'Crane Uptime', 'Berth Disruptions'],
                            cursor.fetchone()))
        for title, value in expected.items():
            if abs(float(metrics[title]) - float(value)) > 1e-4:
                raise RuntimeError(f'KPI {title} failed reconciliation')
        cursor.execute("SELECT MAX(ON_TIME_PCT) - MIN(ON_TIME_PCT) FROM CURATED.PERFORMANCE_SUMMARY")
        if float(cursor.fetchone()[0]) < 1.0:
            raise RuntimeError('Synthetic data lacks variation between berths')
        if not 0 <= metrics['On-Time Box Moves'] <= 100:
            raise RuntimeError('On-time rate outside valid range')
        return {'database': database, 'warehouse': warehouse, 'queries': evidence,
                'berth_count': berth_count, 'observation_count': observations,
                'kpis': metrics, 'scope': 'core only; ML/AI/AWS/app checks not included'}
    finally:
        if created_database:
            # Only the namespace created by this run can be suspended here.
            for table in DYNAMIC_TABLES:
                try:
                    cursor.execute(f'ALTER DYNAMIC TABLE IF EXISTS {database}.CURATED.{table} SUSPEND')
                except Exception:
                    print(f'WARNING: verify suspension for {database}.CURATED.{table}')
        cursor.close()
        connection.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--connection', required=True, help='Snowflake connection name')
    parser.add_argument('--expect-account', help='Optional account locator guard; stops before writes on mismatch')
    parser.add_argument('--database', required=True)
    parser.add_argument('--warehouse', required=True)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    validate_target(args.database, args.warehouse)
    if not args.apply:
        print(json.dumps({'mode': 'dry-run', 'database': args.database, 'warehouse': args.warehouse, 'scripts': FILES}))
        return
    print(json.dumps(run(connect(args.connection), args.database, args.warehouse, args.expect_account), indent=2, default=str))


if __name__ == '__main__':
    main()
