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

    def __init__(self, where: Path, ckan_cmd: List[str], addl_repo: Path,
                 main_ver: GameVersion, other_versions: List[GameVersion],
                 cache_path: Path, game: Game, stability_tolerance: Optional[str]) -> None:
        self.where = where
        self.registry_path = self.where / 'CKAN' / 'registry.json'
        self.ckan_cmd = ckan_cmd
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
        run([*self.ckan_cmd,
             'instance', 'fake',
             '--game', self.game.short_name,
             '--set-default', '--headless',
             'dummy', self.where, str(self.main_ver),
             *self.game.dlc_cmdline_flags(self.main_ver)],
            capture_output=self.capture, check=False)
        for ver in self.other_versions:
            logging.debug('Setting version %s compatible', ver)
            run([*self.ckan_cmd, 'compat', 'add', str(ver)],
                capture_output=self.capture, check=False)
        self.where.joinpath('CKAN', 'downloads').symlink_to(self.cache_path.absolute())
        logging.debug('Setting cache location to %s', self.cache_path.absolute())
        run([*self.ckan_cmd, 'cache', 'set', self.cache_path.absolute(), '--headless'],
            capture_output=self.capture, check=False)
        # Free space plus existing cache minus 1 GB padding
        cache_mbytes = max(5000,
                           (((disk_usage(self.cache_path)[2] if self.cache_path.is_dir() else 0)
                             + sum(f.stat().st_size for f in self.cache_path.rglob('*'))
                             ) // 1024 // 1024 - 1024))
        logging.debug('Setting cache limit to %s', cache_mbytes)
        run([*self.ckan_cmd, 'cache', 'setlimit', str(cache_mbytes)],
            capture_output=self.capture, check=False)
        logging.debug('Adding repo %s', self.addl_repo.as_uri())
        run([*self.ckan_cmd, 'repo', 'add', 'local', self.addl_repo.as_uri()],
            capture_output=self.capture, check=False)
        run([*self.ckan_cmd, 'repo', 'priority', 'local', '0'],
            capture_output=self.capture, check=False)
        if self.stability_tolerance in ('testing', 'development'):
            run([*self.ckan_cmd, 'stability', 'set', self.stability_tolerance],
                capture_output=self.capture, check=False)
        if self.SAVED_REGISTRY.exists():
            logging.debug('Restoring saved registry from %s', self.SAVED_REGISTRY)
            copy(self.SAVED_REGISTRY, self.registry_path)
        else:
            logging.debug('Updating registry')
            run([*self.ckan_cmd, 'update'],
                capture_output=self.capture, check=False)
            copy(self.registry_path, self.SAVED_REGISTRY)
            logging.debug('Saving registry to %s', self.SAVED_REGISTRY)
        logging.debug('Dummy instance is ready')
        return self

    def __exit__(self, exc_type: Type[BaseException],
                 exc_value: BaseException, traceback: TracebackType) -> None:
        logging.debug('Removing instance from CKAN instance list')
        run([*self.ckan_cmd, 'instance', 'forget', 'dummy'],
            capture_output=self.capture, check=False)
        logging.debug('Deleting instance contents')
        rmtree(self.where)
        logging.info('Dummy game instance deleted')
