#!/usr/bin/env python3
"""Portable domain XCTest only; not an iOS/Xcode build. Requires Swift 6 in PATH.

Presentation-only SleepKind colors and view-owned notification declarations are
replaced in the scratch package. One SwiftUI routing test is excluded explicitly.
Hero localization falls back to its English keys; Home card projections are
copied without their SwiftUI view section. All persisted-observation, eligibility,
calendar, accounting and planning logic is copied verbatim.
"""
from pathlib import Path
import os
import shutil
import subprocess
import re
import json

root = Path(__file__).resolve().parent.parent
scratch = root / 'work' / 'trusted-observations-portable'
sources = scratch / 'Sources' / 'BabySleepTracker'
tests = scratch / 'Tests' / 'BabySleepTrackerTests'
sources.mkdir(parents=True, exist_ok=True)
tests.mkdir(parents=True, exist_ok=True)
for folder in [sources, tests]:
    for file in folder.glob('*.swift'):
        file.unlink()
(scratch / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "TrustedObservationsPortable",
    products: [.library(name: "BabySleepTracker", targets: ["BabySleepTracker"])],
    dependencies: [.package(url: "https://github.com/apple/swift-crypto.git", exact: "3.10.0")],
    targets: [.target(name: "BabySleepTracker", dependencies: [.product(name: "Crypto", package: "swift-crypto")]),
              .testTarget(name: "BabySleepTrackerTests", dependencies: ["BabySleepTracker"])],
    swiftLanguageModes: [.v5])
''')
files = [
    'Utils/Date+Extensions.swift', 'Utils/TimeFormat.swift',
    'Models/SleepRecord.swift', 'Models/DailyWakeRecord.swift', 'Models/LearningEligibility.swift',
    'Services/ObservationProvenance.swift', 'Services/SleepRecordPersistence.swift',
    'Services/DailyWakeRecordPersistence.swift', 'Services/SleepRecordingFlow.swift',
    'Services/SleepWakeTimeWorkflow.swift', 'Services/LearningEligibilityEvaluator.swift',
    'Services/SleepOverviewCalculator.swift', 'Services/SleepTimelineCalculator.swift',
    'Services/SleepStateCalculator.swift', 'Services/SleepStore.swift',
    'Agents/Implements/PatternAgent.swift', 'Agents/Protocols/PatternAgentProtocol.swift',
    'Agents/Implements/DaytimePredictionAgent.swift', 'Agents/Protocols/AgeBasedSleepProfile.swift',
    'Agents/Implements/OvertiredCalculator.swift',
    'Agents/Implements/BabyAgeCalculator.swift', 'Agents/Implements/PhaseAgent.swift',
    'Agents/Protocols/PhaseAgentProtocol.swift',
]
for file in files:
    shutil.copyfile(root / 'BabySleepTracker' / file, sources / Path(file).name)
for file in ['Views/Components/TodaySleepHeroModel.swift', 'Models/TodayPlanPresentation.swift']:
    content = (root / 'BabySleepTracker' / file).read_text()
    # Linux Foundation lacks Apple's localized String initializer. Only wording
    # uses this fallback; observation/projection logic remains unchanged.
    content = content.replace('String(localized: ', 'String(')
    (sources / Path(file).name).write_text(content)
card = (root / 'BabySleepTracker/Views/Components/CurrentSleepSessionCard.swift').read_text()
(sources / 'HomeCardProjections.swift').write_text(card[:card.index('private enum HomeCardColor')]
    .replace('import SwiftUI', 'import Foundation'))
legacy = (root / 'BabySleepTracker/Services/SleepCoachOrchestrator.swift').read_text()
(sources / 'DataQualityReport.swift').write_text('import Foundation\n' + legacy[
    legacy.index('enum DataQuality:'):legacy.index('struct OrchestratedSnapshot')])
kind = (root / 'BabySleepTracker/Models/SleepKind.swift').read_text()
kind = kind.split('    // MARK: - UI Helpers')[0].replace('import SwiftUI', 'import Foundation') + '}\n'
(sources / 'SleepKind.swift').write_text(kind)
(sources / 'NotificationNames.swift').write_text('''import Foundation
extension Notification.Name {
    static let sleepRecordsDidChange = Notification.Name("sleepRecordsDidChange")
    static let dailyWakeRecordsDidChange = Notification.Name("dailyWakeRecordsDidChange")
}
''')
def methods(content):
    classes = list(re.finditer(r'(?m)^(?:final )?class (\w+)\s*:\s*XCTestCase\b', content))
    result = set()
    for method in re.finditer(r'(?m)^    func (test\w+)\(', content):
        owners = [item for item in classes if item.start() < method.start()]
        if not owners:
            raise RuntimeError('Test method without an XCTestCase owner')
        identity = 'BabySleepTrackerTests.' + owners[-1].group(1) + '/' + method.group(1)
        if identity in result:
            raise RuntimeError('Duplicate test identity: ' + identity)
        result.add(identity)
    return result

excluded = {'BabySleepTrackerTests.SleepRecordingFlowTests/testOnlyRecordingRoutesUseFullScreenPresentation'}
source_methods = set()
selected_methods = set()
for name in [
    'TrustedObservationCorrectionTests', 'TrustedObservationTests', 'LearningEligibilityEvaluatorTests', 'SleepRecordPersistenceTests',
    'DailyWakeRecordPersistenceTests', 'SleepWakeTimeWorkflowTests', 'SleepRecordTests',
    'DailyWakeRecordTests', 'SleepOverviewCalculatorTests',
    'TodaySleepHeroModelTests', 'HomeDashboardCardTests', 'SleepTimelineCalculatorTests',
    'SleepStateCalculatorTests', 'SleepStoreTests', 'SleepRecordingFlowTests',
]:
    content = (root / 'BabySleepTrackerTests' / (name + '.swift')).read_text()
    original = methods(content)
    source_methods.update(original)
    if name == 'SleepRecordingFlowTests':
        # Match one complete, explicitly named method, including its actor attribute.
        # Method-set validation and SwiftPM discovery below forbid collateral removal.
        pattern = r'(?ms)^    @MainActor\n    func testOnlyRecordingRoutesUseFullScreenPresentation\(\) \{.*?^    \}\n'
        content, count = re.subn(pattern, '', content)
        if count != 1:
            raise RuntimeError('Expected exactly one unsupported SwiftUI method')
    retained = methods(content)
    if original - retained != original & excluded or retained - original:
        raise RuntimeError('Unexpected test-selection change in ' + name)
    selected_methods.update(retained)
    (tests / (name + '.swift')).write_text(content)
if source_methods - selected_methods != excluded:
    raise RuntimeError('Intentional exclusion inventory does not match source')
restored = 'BabySleepTrackerTests.SleepRecordingFlowTests/testOngoingNightDoesNotRequireEndAndPreservesIdentityOnEdit'
if restored not in selected_methods:
    raise RuntimeError('Eligible ongoing-night regression was omitted')
print(f'Source methods: {len(source_methods)}; selected: {len(selected_methods)}; excluded: {len(excluded)}', flush=True)
for identity in sorted(excluded):
    print('Excluded (requires SwiftUI): ' + identity, flush=True)
environment = os.environ.copy()
cache = scratch / 'cache'
cache.mkdir(exist_ok=True)
environment.update(XDG_CACHE_HOME=str(cache), CLANG_MODULE_CACHE_PATH=str(cache / 'clang'),
                   SWIFTPM_MODULECACHE_OVERRIDE=str(cache / 'swift'))
command = ['swift', 'test', '--jobs', '4', '--cache-path', str(cache / 'packages'),
           '--package-path', str(scratch), '--disable-swift-testing']
discovery = subprocess.run(command + ['list'], env=environment, text=True, capture_output=True)
if discovery.stderr:
    print(discovery.stderr, end='', flush=True)
if discovery.returncode:
    print(discovery.stdout)
    raise SystemExit(discovery.returncode)
discovered = [line.strip() for line in discovery.stdout.splitlines()
              if re.fullmatch(r'BabySleepTrackerTests\.\w+/test\w+', line.strip())]
if set(discovered) != selected_methods or len(discovered) != len(selected_methods):
    raise RuntimeError('SwiftPM discovery mismatch: missing=' + repr(sorted(selected_methods - set(discovered))) +
                       '; unexpected=' + repr(sorted(set(discovered) - selected_methods)))
print(f'SwiftPM discovered: {len(discovered)}; restored ongoing-night regression included', flush=True)
run = subprocess.Popen(command + ['--skip-build'], env=environment, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, text=True, bufsize=1)
completed = {}
started = set()
for line in run.stdout:
    print(line, end='', flush=True)
    event = re.match(r"Test Case '(\w+)\.(test\w+)' (started|passed|failed|skipped)\b", line)
    if event:
        identity = 'BabySleepTrackerTests.' + event[1] + '/' + event[2]
        if event[3] == 'started':
            if identity in started:
                raise RuntimeError('Test executed more than once: ' + identity)
            started.add(identity)
        else:
            if identity in completed:
                raise RuntimeError('Duplicate test completion: ' + identity)
            completed[identity] = event[3]
returncode = run.wait()
executed = set(completed)
failed = sum(status == 'failed' for status in completed.values())
skipped = sum(status == 'skipped' for status in completed.values())
print(f'Executed: {len(completed)}; passed: {len(completed) - failed - skipped}; failed: {failed}; skipped: {skipped}', flush=True)
(scratch / 'test-results.json').write_text(json.dumps({
    'source_count': len(source_methods), 'excluded': sorted(excluded),
    'discovered': sorted(discovered), 'completed': completed}, indent=2))
if executed != selected_methods or started != selected_methods:
    raise RuntimeError('Executed XCTest methods do not match validated discovery')
if restored not in executed:
    raise RuntimeError('Ongoing-night regression did not execute')
if returncode or failed or skipped:
    raise SystemExit(returncode or 1)
