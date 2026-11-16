"""Validate focused filters before xcodebuild; never accept a no-test selection."""
import importlib.util
import json
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location('classifier', Path(__file__).with_name('classify-ios.py'))
classifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(classifier)


def filters(suites):
    if (not isinstance(suites, list) or not suites
            or any(not isinstance(s, str) or s not in ['ALL', *classifier.ALL] for s in suites)):
        raise ValueError('Invalid or empty focused selection; refusing a no-test success')
    if 'ALL' in suites:
        return ['-only-testing:BabySleepTrackerUITests']
    return ['-only-testing:BabySleepTrackerUITests/' + s for s in sorted(set(suites))]


if __name__ == '__main__':
    print('\n'.join(filters(json.loads(sys.argv[1]))))
