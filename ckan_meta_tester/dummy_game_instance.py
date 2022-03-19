import logging
from pathlib import Path
from shutil import rmtree, copy
from subprocess import run
from types import TracebackType
from typing import Type, List

from .game_version import GameVersion


class DummyGameInstance:

    SAVED_REGISTRY=Path('/tmp/registry.json')
    MAKING_HISTORY_VERSION=GameVersion('1.4.1')
    BREAKING_GROUND_VERSION=GameVersion('1.7.1')

    def __init__(self, where: Path, ckan_exe: Path, addl_repo: Path, main_ver: GameVersion, other_versions: List[GameVersion], cache_path: Path) -> None:
        self.where = where
        self.registry_path = self.where.joinpath('CKAN').joinpath('registry.json')
        self.ckan_exe = ckan_exe
        self.addl_repo = addl_repo
        self.main_ver = main_ver
        self.other_versions = other_versions
        self.cache_path = cache_path
        # Hide ckan.exe output unless debugging is enabled
        self.capture = not logging.getLogger().isEnabledFor(logging.DEBUG)

    def __enter__(self) -> 'DummyGameInstance':
        logging.info('Creating dummy game instance at %s', self.where)
        self.where.mkdir()
        logging.debug('Populating fake instance contents')
        run(['mono', self.ckan_exe,
             'instance', 'fake',
             '--set-default', '--headless',
             'dummy', self.where, str(self.main_ver),
             *self._available_dlcs(self.main_ver)],
            capture_output=self.capture)
        for ver in self.other_versions:
            logging.debug('Setting version %s compatible', ver)
            run(['mono', self.ckan_exe, 'compat', 'add', str(ver)],
                capture_output=self.capture)
        self.where.joinpath('CKAN').joinpath('downloads').symlink_to(self.cache_path.absolute())
        logging.debug('Setting cache location to %s', self.cache_path.absolute())
        run(['mono', self.ckan_exe, 'cache', 'set', self.cache_path.absolute(), '--headless'],
            capture_output=self.capture)
        logging.debug('Setting cache limit to %s', 5000)
        run(['mono', self.ckan_exe, 'cache', 'setlimit', '5000'],
            capture_output=self.capture)
        logging.debug('Adding repo %s', self.addl_repo.as_uri())
        run(['mono', self.ckan_exe, 'repo', 'add', 'local', self.addl_repo.as_uri()],
            capture_output=self.capture)
        if self.SAVED_REGISTRY.exists():
            logging.debug('Restoring saved registry from %s', self.SAVED_REGISTRY)
            copy(self.SAVED_REGISTRY, self.registry_path)
        else:
            logging.debug('Updating registry')
            run(['mono', self.ckan_exe, 'update'],
                capture_output=self.capture)
            copy(self.registry_path, self.SAVED_REGISTRY)
            logging.debug('Saving registry to %s', self.SAVED_REGISTRY)
        logging.debug('Dummy instance is ready')
        return self

    def _available_dlcs(self, ver: GameVersion) -> List[str]:
        return [
            *(['--MakingHistory',  '1.1.0'] if ver >= self.MAKING_HISTORY_VERSION  else []),
            *(['--BreakingGround', '1.0.0'] if ver >= self.BREAKING_GROUND_VERSION else [])
        ]

    def __exit__(self, exc_type: Type[BaseException],
                 exc_value: BaseException, traceback: TracebackType) -> None:
        logging.debug('Removing instance from CKAN instance list')
        run(['mono', self.ckan_exe, 'instance', 'forget', 'dummy'],
            capture_output=self.capture)
        logging.debug('Deleting instance contents')
        rmtree(self.where)
        logging.info('Dummy game instance deleted')
