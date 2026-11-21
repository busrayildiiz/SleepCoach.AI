"""Recommend explicit UI checkpoints; unknown changes require the entire UI target.

Draft automation records this selection but runs XCTest only. Full merge validation
never consumes these filters.
"""
import json
import subprocess
import sys

ALL = ['HomeDashboardCardUITests', 'TodaySleepHeroUITests',
       'RecordingNavigationTests', 'TodayPlanUITests', 'PrivacyUITests']
HOME_HERO = {'HomeDashboardCardUITests', 'TodaySleepHeroUITests'}
PLAN = {'TodayPlanUITests'}
MAPPINGS = {
    'BabySleepTracker/Models/TodayPlanPresentation.swift': PLAN,
    'BabySleepTracker/Views/Components/TodayPlanCard.swift': PLAN,
    'BabySleepTracker/Views/Components/TodaySleepHeroCard.swift': HOME_HERO | PLAN,
    'BabySleepTracker/Views/Components/TodaySleepHeroModel.swift': HOME_HERO | PLAN,
    'BabySleepTracker/Views/Components/CurrentSleepSessionCard.swift': HOME_HERO,
}
RECORDING = {'AddRecordView.swift', 'AddBreakView.swift', 'RecordingFormComponents.swift',
             'RecordingIntervalRing.swift'}
# Shared navigation can affect every scenario, including newly added UI suites.
SHARED = {'BabySleepTracker/Views/SleepListView.swift',
          'BabySleepTracker/Views/SleepListSheetRouter.swift',
          'BabySleepTracker/Views/ContentView.swift',
          'BabySleepTracker/Services/SleepRecordingFlow.swift',
          'BabySleepTracker/Views/HistoryView.swift',
          'BabySleepTracker/Views/DayDetailView.swift'}


def classify(paths):
    selected = set()
    for path in paths:
        if path.startswith('docs/') or path in ('README.md', 'AGENTS.md'):
            continue
        if path.startswith('BabySleepTrackerTests/'):
            continue  # Complete XCTest runs independently.
        if path in SHARED:
            return ['ALL']
        if path.startswith('BabySleepTrackerUITests/'):
            suite = path.rsplit('/', 1)[-1].removesuffix('.swift')
            if suite not in ALL:
                return ['ALL']
            selected.add(suite)
        elif path in MAPPINGS:
            selected.update(MAPPINGS[path])
        elif path.startswith('BabySleepTracker/Views/') and path.rsplit('/', 1)[-1] in RECORDING:
            selected.add('RecordingNavigationTests')
        else:
            return ['ALL']
    return sorted(selected)


if __name__ == '__main__':
    try:
        result = subprocess.run(['git', 'diff', '--name-only', '-z', '--no-renames',
                                 sys.argv[1], sys.argv[2]], check=True, capture_output=True)
        suites = classify([p for p in result.stdout.decode().split('\0') if p])
    except Exception as error:
        print(f'Classification failed; selecting all UI suites: {error}', file=sys.stderr)
        suites = ['ALL']
    print(json.dumps(suites))
