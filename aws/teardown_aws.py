"""Remove the AWS + account-level Snowflake resources created by setup_aws.py.

Dry-run by default; --apply deletes. The isolated demo database is not dropped.
"""
import argparse
import json

from setup_aws import ident, names


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--connection', required=True, help='Snowflake connection name')
    ap.add_argument('--expect-account', help='Optional account locator guard; stops before writes on mismatch')
    ap.add_argument('--database', required=True)
    ap.add_argument('--account', required=True)
    ap.add_argument('--region', default='us-west-2')
    ap.add_argument('--prefix', default='sg-manufacturing-port-ops')
    ap.add_argument('--apply', action='store_true')
    args = ap.parse_args()
    db = ident(args.database)
    n = names(args.prefix, args.account, args.region)
    print(json.dumps({'delete': n, 'apply': args.apply}, indent=2))
    if not args.apply:
        return
    import boto3
    from run_core import connect
    iot = boto3.client('iot', region_name=args.region)
    iam = boto3.client('iam')
    s3 = boto3.resource('s3', region_name=args.region)
    try:
        iot.delete_topic_rule(ruleName=n['iot_rule'])
    except iot.exceptions.UnauthorizedException:
        pass
    bucket = s3.Bucket(n['bucket'])
    bucket.objects.all().delete()
    bucket.delete()
    for role, policy in ((n['snowflake_role'], 's3-read-iot'), (n['iot_role'], 's3-put-iot')):
        iam.delete_role_policy(RoleName=role, PolicyName=policy)
        iam.delete_role(RoleName=role)
    user = n['bedrock_user']
    for key in iam.list_access_keys(UserName=user)['AccessKeyMetadata']:
        iam.delete_access_key(UserName=user, AccessKeyId=key['AccessKeyId'])
    iam.delete_user_policy(UserName=user, PolicyName='invoke-claude')
    iam.delete_user(UserName=user)
    cur = connect(args.connection).cursor()
    cur.execute('SELECT CURRENT_ACCOUNT()')
    if args.expect_account and cur.fetchone()[0] != args.expect_account.upper():
        raise RuntimeError('Snowflake identity mismatch')
    for stmt in [f'DROP PIPE IF EXISTS {db}.RAW.LIVE_TELEMETRY_PIPE', f'DROP STAGE IF EXISTS {db}.RAW.IOT_LANDING',
                 f'DROP FUNCTION IF EXISTS {db}.APP.BEDROCK_GENERATE(VARCHAR)',
                 f"DROP INTEGRATION IF EXISTS {n['eai']}", f"DROP INTEGRATION IF EXISTS {n['storage_int']}",
                 f'DROP SECRET IF EXISTS {db}.APP.BEDROCK_CREDENTIALS']:
        cur.execute(stmt)
    print('deleted')


if __name__ == '__main__':
    main()
