import re
from os import environ, makedirs
from shutil import copy
import logging
from subprocess import run, Popen, PIPE, STDOUT
from pathlib import Path
from importlib.resources import read_text
from string import Template
from typing import Optional, Iterable, Set, List, Any, Tuple, OrderedDict as OD
from collections import OrderedDict
from tempfile import TemporaryDirectory
from git import Repo, DiffIndex
from exitstatus import ExitStatus

from netkan.repos import CkanMetaRepo

from .ckan_install import CkanInstall
from .game import Game
from .game_version import GameVersion
from .dummy_game_instance import DummyGameInstance
from .log_group import LogGroup


class CkanMetaTester:

    # Location of the netkan.exe and ckan.exe files in the container
    BIN_PATH    = Path('/usr/local/bin')
    NETKAN_PATH = BIN_PATH.joinpath('netkan.exe')
    CKAN_PATH   = BIN_PATH.joinpath('ckan.exe')
    USER_AGENT  = 'Mozilla/5.0 (compatible; Netkanbot/1.0; CKAN; +https://github.com/KSP-CKAN/xKAN-meta_testing)'

    INFLATED_PATH = Path('.ckans')
    CACHE_PATH    = Path('.cache')
    REPO_PATH     = Path('.repo').resolve()
    TINY_REPO     = REPO_PATH.joinpath('metadata.tar.gz')

    CKAN_INSTALL_TEMPLATE = Template(read_text(
        'ckan_meta_tester', 'ckan_install_template.txt'))
    CKAN_INSTALL_IDENTIFIERS_TEMPLATE = Template(read_text(
        'ckan_meta_tester', 'ckan_install_identifiers_template.txt'))

    PR_BODY_COMPAT_PATTERN = re.compile(r'ckan compat add((?: [0-9.]+)+)')
    PR_BODY_TESTS_PATTERN = re.compile(r'ckan install((?: [A-Za-z][A-Za-z0-9-]*(?:=\S+)?)+)')

    GNU_LINE_COL_PATTERN = re.compile(r'^[^:]+:(?P<line>[0-9]+)[:.](?P<col>[0-9]+)')

    REF_ENV_VARS = [
        'PR_BASE_SHA',
        'EVENT_BEFORE'
    ]

    def __init__(self, i_am_the_bot: bool, game_id: str) -> None:
        self.source_to_ckans: OD[Path, List[Path]] = OrderedDict()
        self.failed = False
        self.i_am_the_bot = i_am_the_bot
        self.game = Game.from_id(game_id)
        makedirs(self.INFLATED_PATH, exist_ok=True)
        makedirs(self.REPO_PATH, exist_ok=True)

    def debug_action(self) -> None:
        if int(environ.get('RUNNER_DEBUG', 0)) == 0:
            return
        working = Path('.')
        logging.debug('Current Working: %s', working.cwd())
        logging.debug('Files: %s', ', '.join([str(x) for x in working.glob('*')]))
        logging.debug('Repo: %s', Repo('.').git_dir)

    def test_metadata(self, source: str = 'netkans', pr_body: str = '', github_token: Optional[str] = None, diff_meta_root: Optional[str] = None) -> bool:

        # Work around issue noted in noted in KSP-CKAN/NetKAN#9527
        Repo('.').git.execute(['git', 'config', '--global', '--add', 'safe.directory', '/github/workspace'])
        logging.debug('Starting metadata test')
        self.debug_action()
        logging.debug('Builds: %s', [str(v) for v in self.game.versions])

        # Escape hatch in case author replaces a download after a previous success
        # (which will save it to the persistent cache)
        overwrite_cache = ('#overwrite_cache' in pr_body)
        logging.debug('overwrite_cache: %s', overwrite_cache)

        if not self.CACHE_PATH.exists():
            self.CACHE_PATH.mkdir()

        # Action inputs are apparently '' rather than None if not set in the yml
        meta_repo = CkanMetaRepo(Repo(Path(diff_meta_root))) if diff_meta_root else None

        for file in self.files_to_test(source):
            if len(pr_body) < 1:
                # Warn for empty PR body on every file so it's noticeable in the files changed tab
                print(f'::warning file={file}::Pull requests should have a description with a summary of the changes')
            if not self.test_file(file, overwrite_cache, github_token, meta_repo):
                logging.error('Test of %s failed!', file)
                self.failed = True
        if self.failed:
            return False

        if len(self.source_to_ckans) == 0:
            logging.info('No .ckans found, done.')
            return True

        # Make secondary repo file with our generated .ckans
        run(['tar', 'czf', self.TINY_REPO, '-C', self.INFLATED_PATH, '.'],
            check=True)

        for orig_file, files in self.source_to_ckans.items():
            logging.debug('Installing files for %s: %s', orig_file, files)
            for file in files:
                if not self.install_ckan(file, orig_file, pr_body, meta_repo):
                    logging.error('Install of %s failed!', file)
                    self.failed = True

        for identifiers in self.pr_body_tests(pr_body):
            logging.debug('Installing identifiers: %s', ' '.join(identifiers))
            if not self.install_identifiers(identifiers, pr_body):
                logging.error('Install of %s failed!', ' '.join(identifiers))
                self.failed = True

        return not self.failed

    def test_file(self, file: Path, overwrite_cache: bool, github_token: Optional[str] = None, meta_repo: Optional[CkanMetaRepo] = None) -> bool:
        logging.debug('Attempting jsonlint for %s', file)
        suffix = file.suffix.lower()
        if suffix == '.netkan':
            if not self.run_for_file(
                file, ['yamllint', '-f', 'github', '-d', '{extends: relaxed, rules: {colons: disable}}', file]):
                logging.debug('yamllint failed for %s', file)
                return False
            return self.inflate_file(file, overwrite_cache, github_token, meta_repo)
        if suffix == '.ckan':
            if not self.run_for_file(
                file, ['jsonlint', '-s', '-v', file], full_output_as_error=True, gnu_line_col_fmt=True):
                logging.debug('jsonlint failed for %s', file)
                return False
            return self.validate_file(file, overwrite_cache, github_token)
        raise ValueError(f'Cannot test file {file}, must be .netkan or .ckan')

    def inflate_file(self, file: Path, overwrite_cache: bool, github_token: Optional[str] = None, meta_repo: Optional[CkanMetaRepo] = None) -> bool:
        high_ver = meta_repo.highest_version(file.stem) if meta_repo else None
        with LogGroup(f'Inflating {file}'):
            with TemporaryDirectory() as tempdirname:
                temppath = Path(tempdirname)
                logging.debug('Inflating into %s', temppath)
                if not self.run_for_file(
                    file,
                    ['mono', self.NETKAN_PATH,
                     '--game', self.game.short_name,
                     *(['--github-token', github_token] if github_token is not None else []),
                     '--cachedir', self.CACHE_PATH,
                     *(['--highest-version', str(high_ver)] if high_ver else []),
                     *(['--overwrite-cache'] if overwrite_cache else []),
                     '--outputdir', temppath,
                     file]):
                    return False
                ckans = list(temppath.rglob('*.ckan'))
                for ckan in ckans:
                    print(f'{ckan.name}:')
                    print(ckan.read_text())
                    logging.debug('Copying %s to %s', ckan, self.INFLATED_PATH)
                    copy(ckan, self.INFLATED_PATH)
                self.source_to_ckans[file] = [self.INFLATED_PATH.joinpath(ckan.name)
                                              for ckan in ckans]
                logging.debug('Files generated: %s', self.source_to_ckans[file])
        return True

    def validate_file(self, file: Path, overwrite_cache: bool, github_token: Optional[str] = None) -> bool:
        with LogGroup(f'Validating {file}'):
            if not self.run_for_file(
                file,
                ['mono', self.NETKAN_PATH,
                 '--game', self.game.short_name,
                 *(['--github-token', github_token] if github_token is not None else []),
                 '--cachedir', self.CACHE_PATH,
                 '--net-useragent', self.USER_AGENT,
                 *(['--overwrite-cache'] if overwrite_cache else []),
                 '--validate-ckan', file]):
                return False
            copy(file, self.INFLATED_PATH)
            self.source_to_ckans[file] = [self.INFLATED_PATH.joinpath(file.name)]
            return True

    def install_ckan(self, file: Path, orig_file: Path, pr_body: Optional[str], meta_repo: Optional[CkanMetaRepo]) -> bool:
        logging.debug('Trying to install %s', file)
        ckan = CkanInstall(file)
        if meta_repo is not None:
            diff = ckan.find_diff(meta_repo)
            if diff is not None:
                with LogGroup(f'Diffing {ckan.name} {ckan.version}'):
                    print(diff, end='', flush=True)
        with LogGroup(f'Installing {ckan.name} {ckan.version}'):
            versions = [*self.pr_body_versions(pr_body),
                        *ckan.compat_versions(self.game)]
            if len(versions) < 1:
                print(f'::error file={orig_file}::{file} is not compatible with any game versions!', flush=True)
                return False

            with DummyGameInstance(
                Path('/game-instance'), self.CKAN_PATH, self.TINY_REPO,
                versions[-1], versions[:-1], self.CACHE_PATH, self.game):

                return self.run_for_file(
                    orig_file,
                    ['mono', self.CKAN_PATH, 'prompt', '--headless',
                     '--net-useragent', self.USER_AGENT],
                    input_str=self.CKAN_INSTALL_TEMPLATE.substitute(
                        ckanfile=file, identifier=ckan.identifier))

    def install_identifiers(self, identifiers: List[str], pr_body: Optional[str]) -> bool:
        logging.debug('Trying to install %s', ' '.join(identifiers))
        with LogGroup(f'Installing {" ".join(identifiers)}'):
            versions = self.pr_body_versions(pr_body)
            if len(versions) < 1:
                print('::error::No game versions specified!', flush=True)
                return False

            with DummyGameInstance(
                Path('/game-instance'), self.CKAN_PATH, self.TINY_REPO,
                versions[-1], versions[:-1], self.CACHE_PATH, self.game):

                return self.run_for_file(
                    None,
                    ['mono', self.CKAN_PATH, 'prompt', '--headless'],
                    input_str=self.CKAN_INSTALL_IDENTIFIERS_TEMPLATE.substitute(
                        identifiers=' '.join(identifiers)))

    def pr_body_versions(self, pr_body: Optional[str]) -> List[GameVersion]:
        if not pr_body:
            return []
        logging.debug('Trying to extract versions from %s', pr_body)
        match = self.PR_BODY_COMPAT_PATTERN.search(pr_body)
        return [] if not match else list(map(
            GameVersion,
            match.group(1).strip().split(' ')))

    def pr_body_tests(self, pr_body: Optional[str]) -> Iterable[List[str]]:
        return [] if not pr_body else (
            match.strip().split(' ')
            for match
            in self.PR_BODY_TESTS_PATTERN.findall(pr_body))

    def files_to_test(self, source: Optional[str]) -> Iterable[Path]:
        if not source:
            raise ValueError('Source cannot be None')
        if source == 'netkans':
            return self.netkans()
        if source == 'commits':
            return self.paths_from_diff(self.branch_diff(Repo('.')))
        raise ValueError(f'Source {source} is not valid, must be netkans or commits')

    def netkans(self) -> Iterable[Path]:
        logging.debug('Searching repo for netkan files')
        return (f for f in Path().rglob('*')
                if f.is_file() and f.suffix.lower() == '.netkan')

    def branch_diff(self, repo: Repo) -> Optional[DiffIndex]:
        start_ref = self.get_start_ref()
        logging.debug('Looking for merge base between %s and %s', start_ref, repo.head.commit.hexsha)
        start_commit = repo.commit(start_ref)
        # Has one item or none
        common_ancestors = repo.merge_base(start_commit, repo.head.commit)
        if len(common_ancestors) < 1:
            raise ValueError(f'Could not find common ancestor between start ref {start_commit.hexsha}'
                             f' and HEAD {repo.head.commit.hexsha}')
        merge_base = common_ancestors[0]
        if not merge_base:
            return None
        logging.debug('Looking for changes between %s and %s', merge_base, repo.head.commit.hexsha)
        logging.debug('Base commit sha is %s', merge_base.hexsha)
        return merge_base.diff(repo.head.commit)

    def get_start_ref(self, default: str = 'origin/master') -> str:
        ref = None
        stop_early = not logging.getLogger().isEnabledFor(logging.DEBUG)
        for var in self.REF_ENV_VARS:
            val = environ.get(var)
            logging.debug('Ref env var %s is %s', var, val)
            if val and not ref:
                ref = val
                if stop_early:
                    # Print all the vars in debug mode
                    break
        return ref if ref is not None else default

    def paths_from_diff(self, diff: Optional[DiffIndex]) -> Iterable[Path]:
        if diff:
            logging.debug('Searching diff for changed files')
            all_adds, all_mods = self.filenames_from_diff(diff)
            # Existing files probably have valid names, new ones need to be checked
            for file in all_adds:
                if not self.check_added_path(Path(file)):
                    self.failed = True
            files = sorted(all_adds | all_mods)
            return (Path(file) for file in files if self.netkan_or_ckan(file))
        return iter([])

    def filenames_from_diff(self, diff: DiffIndex) -> Tuple[Set[str], Set[str]]:
        added    = {ch.b_path for ch in diff.iter_change_type('A')}
        modified = {ch.b_path for ch in diff.iter_change_type('M')}
        renamed  = {ch.b_path for ch in diff.iter_change_type('R')}
        logging.debug('%s added, %s modified, %s renamed',
            len(added), len(modified), len(renamed))
        return added, modified | renamed

    def netkan_or_ckan(self, filename: str) -> bool:
        logging.debug('Checking whether %s is interesting to us', filename)
        return filename.endswith('.netkan') or filename.endswith('.ckan')

    def check_added_path(self, file: Path) -> bool:
        if file.suffix == '.netkan':
            if file.parts[0] != 'NetKAN':
                print(f'::error file={file}::{file} should be in the NetKAN folder', flush=True)
                return False
            frozen=file.with_suffix('.frozen')
            if frozen.exists():
                print(f'::error file={file}::{file.stem} is frozen, unfreeze it by renaming or deleting {frozen}', flush=True)
                return False
        elif file.suffix == '.ckan':
            if not self.i_am_the_bot:
                print(f'::warning file={file}::Usually we should trust the bot to create .ckan files, are you sure you know what you\'re doing?')
            if len(file.parts) != 2:
                print(f'::error file={file}::{file} should be placed in the folder named after its mod\'s identifier')
                return False
        else:
            print(f'::warning file={file}::To validate {file}, set its extension to .netkan or .ckan', flush=True)
        return True

    def run_for_file(self, file: Optional[Path], cmd: List[Any],
        input_str: Optional[str] = None, full_output_as_error: Optional[bool] = False, gnu_line_col_fmt: Optional[bool] = False) -> bool:

        with Popen(cmd, text=True, universal_newlines=True,
                   stdin=(PIPE if input_str else None), stdout=PIPE, stderr=STDOUT
             ) as cmd_pipe:

            if cmd_pipe is None:
                return False
            if cmd_pipe.stdout is None:
                return False
            if input_str:
                if cmd_pipe.stdin is None:
                    return False
                cmd_pipe.stdin.write(input_str)
                cmd_pipe.stdin.flush()
                cmd_pipe.stdin.close()
            full_output = ''
            for line in iter(cmd_pipe.stdout.readline, ''):
                if full_output_as_error:
                    full_output += line
                elif ' ERROR ' in line or ' FATAL ' in line:
                    if file:
                        print(f'::error file={file}::{line}', flush=True, end='')
                    else:
                        print(f'::error::{line}', flush=True, end='')
                elif ' WARN ' in line:
                    if file:
                        print(f'::warning file={file}::{line}', flush=True, end='')
                    else:
                        print(f'::warning::{line}', flush=True, end='')
                else:
                    print(line, flush=True, end='')
            if cmd_pipe.wait() != ExitStatus.success:
                if full_output_as_error:
                    # This is the crazy method for putting newlines into ::error
                    full_output = full_output.rstrip().replace('\n', '%0A')
                    if gnu_line_col_fmt:
                        # Get the line and column from the start of the output in GNU format
                        # https://www.gnu.org/prep/standards/html_node/Errors.html
                        match = self.GNU_LINE_COL_PATTERN.match(full_output)
                        if match:
                            line_num = match.group('line')
                            col_num = match.group('col')
                            if file:
                                print(f'::error file={file},line={line_num},col={col_num}::{full_output}', flush=True)
                            else:
                                print(f'::error::{full_output}', flush=True)
                        else:
                            if file:
                                print(f'::error file={file}::{full_output}', flush=True)
                            else:
                                print(f'::error::{full_output}', flush=True)
                    else:
                        if file:
                            print(f'::error file={file}::{full_output}', flush=True)
                        else:
                            print(f'::error::{full_output}', flush=True)
                return False
            if full_output_as_error:
                print(full_output.rstrip(), flush=True)
            return True
