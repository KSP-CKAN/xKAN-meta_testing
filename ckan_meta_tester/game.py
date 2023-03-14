import re
import requests
from collections import OrderedDict
from typing import List, Dict, Optional, cast

from .game_version import GameVersion

class Game:
    BUILDS_URL = ''

    def __init__(self) -> None:
        self.versions = self._versions_from_json(
            requests.get(self.BUILDS_URL).json())

    @property
    def short_name(self) -> str:
        raise NotImplementedError

    def _versions_from_json(self, json: object) -> List[GameVersion]:
        raise NotImplementedError

    @staticmethod
    def from_id(game_id: str = 'KSP') -> 'Game':
        if game_id == 'KSP':
            return Ksp1()
        if game_id == 'KSP2':
            return Ksp2()
        raise ValueError('game_id must be either KSP or KSP2')


class Ksp1(Game):
    BUILDS_URL = 'https://raw.githubusercontent.com/KSP-CKAN/CKAN-meta/master/builds.json'
    BUILD_PATTERN=re.compile(r'\.[0-9]+$')

    @property
    def short_name(self) -> str:
        return 'KSP'

    def _versions_from_json(self, json: object) -> List[GameVersion]:

        return [GameVersion(v) for v in OrderedDict.fromkeys(map(
            lambda v: self.BUILD_PATTERN.sub('', v),
            cast(Dict[str, Dict[str, str]], json).get('builds', {}).values()))]


class Ksp2(Game):
    BUILDS_URL = 'https://raw.githubusercontent.com/KSP-CKAN/KSP2-CKAN-meta/master/builds.json'

    @property
    def short_name(self) -> str:
        return 'KSP2'

    def _versions_from_json(self, json: object) -> List[GameVersion]:
        # The KSP2 builds.json doesn't have build ids
        return [GameVersion(v) for v in cast(List[str], json)]
