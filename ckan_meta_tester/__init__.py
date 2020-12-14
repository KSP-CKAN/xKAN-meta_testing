import logging
from os import environ
from exitstatus import ExitStatus

from .ckan_meta_tester import CkanMetaTester


def test_metadata() -> None:
    # setLevel can take a string representation, great!
    logging.getLogger('').setLevel(
        environ.get('INPUT_LOG_LEVEL', 'info').upper())

    ex = CkanMetaTester()
    exit(ExitStatus.success
         if ex.test_metadata(environ.get('INPUT_SOURCE',            'netkans'),
                             environ.get('INPUT_PULL_REQUEST_BODY', ''),
                             environ.get('GITHUB_TOKEN'))
         else ExitStatus.failure)
