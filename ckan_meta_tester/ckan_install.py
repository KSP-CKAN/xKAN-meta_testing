import logging
from difflib import unified_diff
from typing import List, Optional

from netkan.metadata import Ckan
from netkan.repos import CkanMetaRepo

from .game import Game
from .game_version import GameVersion


class CkanInstall(Ckan):
    """Metadata file representation with extensions for installation"""

    def compat_versions(self, game: Game) -> List[GameVersion]:
        minv = self.lowest_compat()
        maxv = self.highest_compat()
        logging.debug('Finding versions from %s to %s', minv, maxv)
        return [v for v in game.versions
                if v.compatible(minv, maxv)]

    def lowest_compat(self) -> GameVersion:
        try:
            return GameVersion(self.ksp_version_min)
        except AttributeError:
            try:
                return GameVersion(self.ksp_version)
            except AttributeError:
                return GameVersion('any')

    def highest_compat(self) -> GameVersion:
        try:
            return GameVersion(self.ksp_version_max)
        except AttributeError:
            try:
                return GameVersion(self.ksp_version)
            except AttributeError:
                return GameVersion('any')

    def find_diff(self, meta_repo: CkanMetaRepo) -> Optional[str]:
        ckans = [ck for ck in meta_repo.ckans(self.identifier)
                 if ck.version == self.version]
        return None if len(ckans) != 1 else ''.join(
            unified_diff(ckans[0].contents.splitlines(True),
                         self.contents.splitlines(True),
                         fromfile=f'Previous {self.name} {self.version}',
                         tofile=f'New {self.name} {self.version}'))
