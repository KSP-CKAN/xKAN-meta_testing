from unittest import TestCase

from ckan_meta_tester.ckan_install import CkanInstall
from ckan_meta_tester.game_version import GameVersion


class TestCkanInstall(TestCase):

    def test_ckan_install(self) -> None:

        # Arrange
        cki = CkanInstall(contents="""{
            "spec_version": "v1.4",
            "identifier":   "NASA-CountDown",
            "version":      "1.3.9.1",
            "ksp_version_min": "1.8",
            "ksp_version_max": "1.10",
            "author":       "linuxgurugamer",
            "license":      "CC-BY-NC-SA",
            "download":     "https://spacedock.info/mod/1462/NASA%20CountDown%20Clock%20Updated/download/1.3.9.1",
            "download_content_type": "application/zip"
        }""")

        # Act / Assert
        self.assertEqual(cki.lowest_compat(), GameVersion('1.8'))
        self.assertEqual(cki.highest_compat(), GameVersion('1.10'))
        self.assertEqual(cki.compat_versions(), [
            GameVersion('1.8.0'), GameVersion('1.8.1'),
            GameVersion('1.9.0'), GameVersion('1.9.1'),
            GameVersion('1.10.0'), GameVersion('1.10.1'),
        ])
