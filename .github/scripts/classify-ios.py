"""Select draft UI suites; unknown changes deliberately select every suite."""
import json
import subprocess
import sys

ALL = ['HomeDashboardCardUITests', 'TodaySleepHeroUITests', 'RecordingNavigationTests']


def classify(paths):
    selected = set()
    for path in paths:
        if path.startswith('docs/') or path in ('README.md', 'AGENTS.md'):
            continue
        if path.startswith('BabySleepTrackerTests/'):
            continue  # All XCTest runs independently.
        if path.startswith('BabySleepTrackerUITests/'):
            suite = path.rsplit('/', 1)[-1].removesuffix('.swift')
            if suite not in ALL:
                return ['ALL']
            selected.add(suite)
        elif path in ('BabySleepTracker/Views/Components/TodaySleepHeroCard.swift',
                      'BabySleepTracker/Views/Components/TodaySleepHeroModel.swift',
                      'BabySleepTracker/Views/Components/CurrentSleepSessionCard.swift'):
            selected.update(ALL[:2])
        elif path.startswith('BabySleepTracker/Views/') and path.rsplit('/', 1)[-1] in (
            'AddRecordView.swift', 'AddBreakView.swift', 'RecordingFormComponents.swift',
            'RecordingIntervalRing.swift'):
            selected.add('RecordingNavigationTests')
        else:
            return ['ALL']  # Includes services, routing, dependencies and CI changes.
    return sorted(selected)


if __name__ == '__main__':
    try:
        result = subprocess.run(['git', 'diff', '--name-only', '-z', '--no-renames',
                                 sys.argv[1], sys.argv[2]], check=True, capture_output=True)
        paths = result.stdout.decode().split('\0')
        suites = classify([p for p in paths if p])
    except Exception as error:
        print(f'Classification failed; selecting all UI suites: {error}', file=sys.stderr)
        suites = ['ALL']
    print(json.dumps(suites))
