from unittest import TestCase

from ckan_meta_tester.game_version import GameVersion


class TestGameVersion(TestCase):

    def test_game_version_str(self) -> None:
        # Arrange
        v = GameVersion('1.2.3')

        # Act / Assert
        self.assertEqual(str(v), '1.2.3')

    def test_game_version_le(self) -> None:
        # Arrange
        smaller = GameVersion('1.2')
        larger  = GameVersion('1.10')
        any     = GameVersion('any')

        # Act / Assert
        self.assertTrue(smaller <= larger)
        self.assertTrue(smaller <= any)
        self.assertTrue(larger <= any)
        self.assertTrue(any <= smaller)
        self.assertTrue(any <= larger)

        self.assertFalse(larger <= smaller)

    def test_game_version_eq(self) -> None:
        # Arrange
        a   = GameVersion('1.0')
        b   = GameVersion('1.0')
        c   = GameVersion('1.0.0')
        any = GameVersion('any')

        # Act / Assert
        self.assertTrue(a == b)
        self.assertTrue(b == a)

        self.assertFalse(a == c)
        self.assertFalse(c == b)
        self.assertFalse(a == any)
        self.assertFalse(b == any)
        self.assertFalse(c == any)

    def test_game_version_compatible(self) -> None:
        # Arrange
        lowest   = GameVersion('1.3.1')
        middle   = GameVersion('1.5.1')
        highest  = GameVersion('1.9.1')
        wildcard = GameVersion('1.5')

        # Act / Assert
        self.assertTrue(middle.compatible(lowest, highest))
        self.assertTrue(middle.compatible(lowest, middle))
        self.assertTrue(middle.compatible(middle, middle))
        self.assertTrue(middle.compatible(middle, highest))

        self.assertTrue(middle.compatible(wildcard, wildcard))

        self.assertFalse(highest.compatible(lowest, middle))
        self.assertFalse(lowest.compatible(middle, highest))
