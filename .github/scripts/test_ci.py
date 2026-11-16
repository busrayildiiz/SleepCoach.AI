import importlib.util
import itertools
import json
import os
import re
import tempfile
import textwrap
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
selection = load('ui-selection')
REPO = ROOT.parent.parent


class RoutingTests(unittest.TestCase):
    def test_docs_and_unit_tests_do_not_schedule_ui(self):
        self.assertEqual(classifier.classify(['docs/ARCHITECTURE.md', 'BabySleepTrackerTests/AuthFlowTests.swift']), [])

    def test_home_selects_both_related_suites(self):
        self.assertEqual(set(classifier.classify(['BabySleepTracker/Views/Components/TodaySleepHeroCard.swift'])), classifier.HOME_HERO | classifier.PLAN)

    def test_plan_paths_and_each_ui_suite(self):
        for path in ['BabySleepTracker/Models/TodayPlanPresentation.swift',
                     'BabySleepTracker/Views/Components/TodayPlanCard.swift']:
            self.assertEqual(classifier.classify([path]), ['TodayPlanUITests'])
        for suite in classifier.ALL:
            self.assertEqual(classifier.classify(['BabySleepTrackerUITests/' + suite + '.swift']), [suite])
        actual = set()
        for path in (REPO / 'BabySleepTrackerUITests').glob('*.swift'):
            actual.update(re.findall(r'final class (\w+): XCTestCase', path.read_text()))
        self.assertEqual(actual, set(classifier.ALL), 'Update mappings for new UI suites')

    def test_selection_preserves_all_and_rejects_empty_or_invalid(self):
        self.assertEqual(selection.filters(['ALL']), ['-only-testing:BabySleepTrackerUITests'])
        self.assertEqual(selection.filters(['TodayPlanUITests']),
                         ['-only-testing:BabySleepTrackerUITests/TodayPlanUITests'])
        for invalid in [[], None, {}, 'ALL', ['NewSuite'], [None], [['ALL']]]:
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                selection.filters(invalid)

    def test_mixed_unknown_change_cannot_narrow_coverage(self):
        self.assertEqual(classifier.classify(['BabySleepTracker/Models/TodayPlanPresentation.swift',
                                              'unknown.swift']), ['ALL'])
        for path in classifier.SHARED:
            self.assertEqual(classifier.classify([path]), ['ALL'])

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


class WorkflowTests(unittest.TestCase):
    def test_actual_event_router_draft_fast_ready_and_other_events_full(self):
        workflow = (REPO / '.github/workflows/ios-ci.yml').read_text()
        block = workflow.split('      - id: select', 1)[1].split('        run: |\n', 1)[1].split('\n  fast-xctest:', 1)[0]
        shell = textwrap.dedent(block)
        for event, draft, expected in [('pull_request', 'true', 'false'),
                                        ('pull_request', 'false', 'true'),
                                        ('merge_group', '', 'true'), ('push', '', 'true'),
                                        ('workflow_dispatch', '', 'true')]:
            with self.subTest(event=event, draft=draft), tempfile.TemporaryDirectory() as tmp:
                output = pathlib.Path(tmp) / 'outputs'
                env = dict(os.environ, EVENT_NAME=event, DRAFT=draft, BASE_SHA='HEAD',
                           HEAD_SHA='HEAD', GITHUB_OUTPUT=str(output),
                           GITHUB_STEP_SUMMARY=str(pathlib.Path(tmp) / 'summary'))
                subprocess.run(['bash', '-eu', '-c', shell], cwd=REPO, env=env, check=True)
                self.assertIn('full=' + expected, output.read_text().splitlines())
        self.assertNotIn('  focused-ui:', workflow)
        self.assertIn("if: needs.classify.outputs.full == 'false'", workflow)
        self.assertIn('simulator: [standard, compact]', workflow)
        self.assertIn('if: always()\n    needs: [classify, full-validation]', workflow)

    def test_checkpoint_is_manual_pinned_and_rechecks_freshness(self):
        workflow = (REPO / '.github/workflows/ios-ui-checkpoint.yml').read_text()
        self.assertIn('  workflow_dispatch:', workflow)
        for event in ['pull_request:', 'pull_request_target:', 'issue_comment:', 'push:']:
            self.assertNotIn(event, workflow)
        self.assertEqual(workflow.count("check-ui-request.js').run"), 2)
        self.assertIn('checkout_sha: ${{ needs.validate-request.outputs.head }}', workflow)
        self.assertNotIn('merge-validation:', workflow)
        subprocess.run(['node', '--test', str(ROOT / 'test-ui-request.cjs')], check=True)


if __name__ == '__main__':
    unittest.main()
