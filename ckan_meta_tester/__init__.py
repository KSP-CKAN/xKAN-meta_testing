import sys
import logging
from os import environ
from typing import Optional
from exitstatus import ExitStatus

from .ckan_meta_tester import CkanMetaTester


def test_metadata() -> None:
    # setLevel can take a string representation, great!
    log_level = environ.get('INPUT_LOG_LEVEL', 'info').upper()
    if int(environ.get('RUNNER_DEBUG', 0)) == 1:
        log_level = 'debug'
    logging.getLogger('').setLevel(log_level.upper())

    github_token = environ.get('GITHUB_TOKEN')

    ex = CkanMetaTester(environ.get('GITHUB_ACTOR') == 'netkan-bot',
                        environ.get('INPUT_GAME', 'KSP'))
    sys.exit(ExitStatus.success
             if ex.test_metadata(environ.get('INPUT_SOURCE', 'netkans'),
                                 environ.get('INPUT_PULL_REQUEST_URL'),
                                 github_token,
                                 environ.get('INPUT_DIFF_META_ROOT'))
             else ExitStatus.failure)
