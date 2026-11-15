"""Fail closed: only full validation of this revision can approve a merge."""
import os
import sys


def approved(classification, full_required, full_result):
    return (classification, full_required, full_result) == ('success', 'true', 'success')


if __name__ == '__main__':
    if not approved(os.environ['CLASSIFY_RESULT'], os.environ['FULL_REQUIRED'], os.environ['FULL_RESULT']):
        sys.exit('Merge blocked: full validation on both simulators must succeed for this revision.')
