import unittest
from collect import correlate, digest

class CorrelationTests(unittest.TestCase):
    def bundle(self, lease='one', sequence=1):
        return {'manifest': {'recordCount': 1}, 'records': [{
            'schema': 'koeon.field-journal.v1', 'event': 'RX_PCM', 'wallTimeMs': 1000,
            'runId': '11111111-1111-1111-1111-111111111111', 'sequence': sequence,
            'installationId': '22222222-2222-2222-2222-222222222222', 'monotonicMs': 123,
            'correlation': {'leaseHash': digest(lease)}, 'data': {'firstPcm': True, 'token': 'secret'}}]}
    def test_server_matches_hashed_lease_and_preserves_offset_without_leaks(self):
        result = correlate([('phone', self.bundle())], [('server', {'wallTimeMs': 900, 'event': 'FLOOR_GRANTED',
            'leaseId': 'one', 'token': 'secret', 'message': 'private'})], {'phone': -100})
        self.assertEqual(result['leases'][0]['sources'], ['phone', 'server'])
        self.assertEqual(result['records'][0]['adjustedTimeMs'], 900)
        self.assertEqual(result['records'][0]['wallTimeMs'], 1000)
        self.assertNotIn('secret', str(result)); self.assertNotIn('private', str(result))
        self.assertEqual(result['leases'][0]['audibility'], 'NOT_MEASURED')
    def test_duplicate_distinct_leases_and_rejected_rows(self):
        a = self.bundle(); b = self.bundle('two', 3)
        b['records'].append({'schema': 'invalid'})
        result = correlate([('a', a), ('again', a), ('b', b)])
        self.assertEqual(result['duplicateRecords'], 1)
        self.assertEqual(result['rejectedRecords'], 1)
        self.assertEqual(len(result['leases']), 2)
    def test_no_match_inferred_from_time(self):
        a = self.bundle(); a['records'][0]['correlation'] = {}
        result = correlate([('a', a)])
        self.assertEqual(result['leases'], []); self.assertEqual(result['uncorrelatedRecords'], 1)
    def test_invalid_data_and_server_raw_fields_are_discarded(self):
        a = self.bundle(); a['records'][0]['data'] = {'route': 'private device', 'gainDb': float('nan')}
        result = correlate([('a', a)], [('s', None)])
        self.assertEqual(result['records'][0]['data'], {})
        self.assertEqual(result['rejectedRecords'], 1)

if __name__ == '__main__': unittest.main()
