import json
import random
import sys
import unittest
from pathlib import Path

import botocore.session
from botocore.validate import ParamValidator

sys.path.insert(0, str(Path(__file__).resolve().parent))
from publish_telemetry import TOPIC, build_message, publish_request
from setup_aws import TOPIC as RULE_TOPIC


class PublishTelemetryTests(unittest.TestCase):
    def test_publish_request_matches_botocore_schema(self):
        model = botocore.session.get_session().get_service_model('iot-data')
        shape = model.operation_model('Publish').input_shape
        request = publish_request(build_message(random.Random(7)))
        report = ParamValidator().validate(request, shape)
        self.assertFalse(report.has_errors(), report.generate_report())

    def test_message_fields_match_snowpipe_copy(self):
        message = json.loads(publish_request(build_message(random.Random(1)))['payload'])
        self.assertEqual(set(message), {'berth_id', 'event_ts', 'vessel_wait_hours',
                                        'berth_occupancy_pct', 'status'})
        self.assertRegex(message['berth_id'], r'^BT-00[0-2][0-9]$')
        self.assertIn(message['status'], {'ALARM', 'NORMAL'})

    def test_topic_matches_iot_rule(self):
        self.assertEqual(TOPIC, RULE_TOPIC)


if __name__ == '__main__':
    unittest.main()
