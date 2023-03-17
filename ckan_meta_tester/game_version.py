import re
import logging
from functools import total_ordering
from typing import Match, Optional


@total_ordering
class GameVersion:

    VERSION_PATTERN = re.compile(
        '^(?P<major>\d+)(\.(?P<minor>\d+))?(\.(?P<patch>\d+))?(\.(?P<build>\d+))?$')

    def __init__(self, val: str) -> None:
        self.val = val
        if self.val == 'any':
            self.major = None
            self.minor = None
            self.patch = None
            self.build = None
        else:
            match = self.VERSION_PATTERN.fullmatch(self.val)
            if match is None:
                raise TypeError(f'Malformed game version: {self.val}')
            self.major = self._get_int_group(match, 'major')
            self.minor = self._get_int_group(match, 'minor')
            self.patch = self._get_int_group(match, 'patch')
            self.build = self._get_int_group(match, 'build')

    def compatible(self, minv: 'GameVersion', maxv: 'GameVersion') -> bool:
        return minv <= self <= maxv

    def __le__(self, other: 'GameVersion') -> bool:
        if self._piece_lt(self.major, other.major):
            return True
        if not self._piece_le(self.major, other.major):
            return False
        if self._piece_lt(self.minor, other.minor):
            return True
        if not self._piece_le(self.minor, other.minor):
            return False
        if self._piece_lt(self.patch, other.patch):
            return True
        if not self._piece_le(self.patch, other.patch):
            return False
        if self._piece_lt(self.build, other.build):
            return True
        if not self._piece_le(self.build, other.build):
            return False
        return True

    def _piece_lt(slef, a: Optional[int], b: Optional[int]) -> bool:
        return a is not None and b is not None and a < b

    def _piece_le(self, a: Optional[int], b: Optional[int]) -> bool:
        return a is None or b is None or a <= b

    def __eq__(self, other: object) -> bool:
        if isinstance(other, GameVersion):
            return self.major == other.major \
                and self.minor == other.minor \
                and self.patch == other.patch \
                and self.build == other.build
        return False

    def _get_int_group(self, match: Match[str], groupName: str) -> Optional[int]:
        matched = match.group(groupName)
        return int(matched) if matched else None

    def __str__(self) -> str:
        return self.val

    def __repr__(self) -> str:
        return f'<GameVersion({self.val})>'
