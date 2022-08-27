import sys
import logging
from os import environ
from typing import Optional
from urllib.parse import urlparse
import requests
from exitstatus import ExitStatus

from .ckan_meta_tester import CkanMetaTester


def test_metadata() -> None:
    # setLevel can take a string representation, great!
    logging.getLogger('').setLevel(
        environ.get('INPUT_LOG_LEVEL', 'info').upper())

    github_token = environ.get('GITHUB_TOKEN')

    ex = CkanMetaTester(environ.get('GITHUB_ACTOR') == 'netkan-bot')
    sys.exit(ExitStatus.success
             if ex.test_metadata(environ.get('INPUT_SOURCE', 'netkans'),
                                 get_pr_body(github_token, environ.get('INPUT_PULL_REQUEST_URL')),
                                 github_token,
                                 environ.get('INPUT_DIFF_META_ROOT'))
             else ExitStatus.failure)


def get_pr_body(github_token: Optional[str], pr_url: Optional[str]) -> str:
    # Get PR body text
    if pr_url:
        headers = { 'Accept': 'application/vnd.github.v3.raw+json' }
        parsed_pr_url = urlparse(pr_url)
        if github_token:
            if parsed_pr_url.scheme == 'https' and parsed_pr_url.netloc == 'api.github.com' \
                    and parsed_pr_url.path.startswith('/repos/'):
                headers['Authorization'] = f'token {github_token}'
            else:
                logging.warning('Invalid pull request url, omitting Authorization header')

        resp = requests.get(pr_url, headers=headers, timeout=30)
        if resp.ok:
            # If the PR has an empty body, 'body' is set to None, not the empty string
            return resp.json().get('body') or ''
        logging.warning(resp.text)
    return ''
