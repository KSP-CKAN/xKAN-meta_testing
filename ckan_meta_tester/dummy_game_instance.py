import logging
from pathlib import Path
from shutil import rmtree, copy, disk_usage
from subprocess import run
from types import TracebackType
from typing import Type, List, Optional

from .game import Game
from .game_version import GameVersion


class DummyGameInstance:
    SAVED_REGISTRY=Path('/tmp/registry.json')

    def __init__(self, where: Path, ckan_exe: Path, addl_repo: Path,
                 main_ver: GameVersion, other_versions: List[GameVersion],
                 cache_path: Path, game: Game, stability_tolerance: Optional[str]) -> None:
        self.where = where
        self.registry_path = self.where.joinpath('CKAN').joinpath('registry.json')
        self.ckan_exe = ckan_exe
        self.addl_repo = addl_repo
        self.main_ver = main_ver
        self.other_versions = other_versions
        self.cache_path = cache_path
        self.game = game
        self.stability_tolerance = stability_tolerance
        # Hide ckan.exe output unless debugging is enabled
        self.capture = not logging.getLogger().isEnabledFor(logging.DEBUG)

    def __enter__(self) -> 'DummyGameInstance':
        logging.info('Creating dummy game instance at %s', self.where)
        self.where.mkdir()
        logging.debug('Populating fake instance contents')
        run(['mono', self.ckan_exe,
             'instance', 'fake',
             '--game', self.game.short_name,
             '--set-default', '--headless',
             'dummy', self.where, str(self.main_ver),
             *self.game.dlc_cmdline_flags(self.main_ver)],
            capture_output=self.capture, check=False)
        for ver in self.other_versions:
            logging.debug('Setting version %s compatible', ver)
            run(['mono', self.ckan_exe, 'compat', 'add', str(ver)],
                capture_output=self.capture, check=False)
        self.where.joinpath('CKAN').joinpath('downloads').symlink_to(self.cache_path.absolute())
        logging.debug('Setting cache location to %s', self.cache_path.absolute())
        run(['mono', self.ckan_exe, 'cache', 'set', self.cache_path.absolute(), '--headless'],
            capture_output=self.capture, check=False)
        # Free space plus existing cache minus 1 GB padding
        cache_mbytes = max(5000,
                           (((disk_usage(self.cache_path)[2] if self.cache_path.is_dir() else 0)
                             + sum(f.stat().st_size for f in self.cache_path.rglob('*'))
                             ) // 1024 // 1024 - 1024))
        logging.debug('Setting cache limit to %s', cache_mbytes)
        run(['mono', self.ckan_exe, 'cache', 'setlimit', str(cache_mbytes)],
            capture_output=self.capture, check=False)
        logging.debug('Adding repo %s', self.addl_repo.as_uri())
        run(['mono', self.ckan_exe, 'repo', 'add', 'local', self.addl_repo.as_uri()],
            capture_output=self.capture, check=False)
        run(['mono', self.ckan_exe, 'repo', 'priority', 'local', '0'],
            capture_output=self.capture, check=False)
        if self.stability_tolerance in ('testing', 'development'):
            run(['mono', self.ckan_exe, 'stability', 'set', self.stability_tolerance],
                capture_output=self.capture, check=False)
        if self.SAVED_REGISTRY.exists():
            logging.debug('Restoring saved registry from %s', self.SAVED_REGISTRY)
            copy(self.SAVED_REGISTRY, self.registry_path)
        else:
            logging.debug('Updating registry')
            run(['mono', self.ckan_exe, 'update'],
                capture_output=self.capture, check=False)
            copy(self.registry_path, self.SAVED_REGISTRY)
            logging.debug('Saving registry to %s', self.SAVED_REGISTRY)
        logging.debug('Dummy instance is ready')
        return self

    def __exit__(self, exc_type: Type[BaseException],
                 exc_value: BaseException, traceback: TracebackType) -> None:
        logging.debug('Removing instance from CKAN instance list')
        run(['mono', self.ckan_exe, 'instance', 'forget', 'dummy'],
            capture_output=self.capture, check=False)
        logging.debug('Deleting instance contents')
        rmtree(self.where)
        logging.info('Dummy game instance deleted')
