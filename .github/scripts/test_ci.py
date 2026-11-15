import importlib.util
import itertools
import json
import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).parent


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


classifier = load('classify-ios')
gate = load('check-merge-gate')


class RoutingTests(unittest.TestCase):
    def test_docs_and_unit_tests_do_not_schedule_ui(self):
        self.assertEqual(classifier.classify(['docs/ARCHITECTURE.md', 'BabySleepTrackerTests/AuthFlowTests.swift']), [])

    def test_home_selects_both_related_suites(self):
        self.assertEqual(set(classifier.classify(['BabySleepTracker/Views/Components/TodaySleepHeroCard.swift'])), set(classifier.ALL[:2]))

    def test_recording_selects_navigation(self):
        self.assertEqual(classifier.classify(['BabySleepTracker/Views/AddRecordView.swift']), ['RecordingNavigationTests'])

    def test_unknown_and_shared_changes_broaden_selection(self):
        for path in ['new-file.swift', '.github/workflows/ios-ci.yml', 'BabySleepTracker/Services/SleepStore.swift', 'BabySleepTracker/Views/SleepListView.swift', 'BabySleepTrackerUITests/NewTests.swift']:
            with self.subTest(path=path):
                self.assertEqual(classifier.classify([path]), ['ALL'])

    def test_invalid_diff_falls_back_to_all_ui(self):
        result = subprocess.run(['python3', str(ROOT / 'classify-ios.py'), 'invalid-ref', 'also-invalid'], capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(result.stdout), ['ALL'])
        self.assertIn('Classification failed', result.stderr)

    def test_only_successful_full_validation_opens_gate(self):
        outcomes = ['success', 'failure', 'cancelled', 'skipped', '']
        for classification, full_required, full_result in itertools.product(outcomes, ['true', 'false', ''], outcomes):
            with self.subTest(classification=classification, full_required=full_required, full_result=full_result):
                self.assertEqual(gate.approved(classification, full_required, full_result),
                                 classification == 'success' and full_required == 'true' and full_result == 'success')


if __name__ == '__main__':
    unittest.main()
