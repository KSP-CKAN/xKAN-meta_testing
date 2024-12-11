from pathlib import Path, PosixPath
import unittest.util
from unittest import TestCase
from unittest.mock import Mock, patch, call

from ckan_meta_tester.game import Game
from ckan_meta_tester.game_version import GameVersion
from ckan_meta_tester.dummy_game_instance import DummyGameInstance


class TestDummyGameInstance(TestCase):

    # Go nuts with trying to intercept filesystem calls,
    # will probably break if we change how we import things
    @patch('ckan_meta_tester.dummy_game_instance.run')
    @patch('ckan_meta_tester.dummy_game_instance.rmtree')
    @patch('ckan_meta_tester.dummy_game_instance.copy')
    @patch('ckan_meta_tester.dummy_game_instance.Path.symlink_to')
    @patch('ckan_meta_tester.dummy_game_instance.Path.mkdir')
    def test_dummy_game_instance_calls(self,
        mocked_mkdir: Mock,
        mocked_symlink_to: Mock,
        mocked_copy: Mock,
        mocked_rmtree: Mock,
        mocked_run: Mock) -> None:

        # Arrange
        unittest.util._MAX_LENGTH=999999999 # type: ignore # pylint: disable=protected-access

        # Act
        with DummyGameInstance(
            Path('/game-instance'),
            Path('/ckan.exe'),
            Path('/repo/metadata.tar.gz'),
            GameVersion('1.8.1'),
            [GameVersion('1.8.0')],
            Path('/cache'),
            Game.from_id('KSP'),
            None):

            pass

        # Assert
        self.assertEqual(mocked_mkdir.mock_calls, [call()])
        self.assertEqual(mocked_symlink_to.mock_calls, [
            call(PosixPath('/cache'))
        ])
        self.assertEqual(mocked_copy.mock_calls, [
            call(PosixPath('/game-instance/CKAN/registry.json'),
                 PosixPath('/tmp/registry.json'))
        ])
        self.assertEqual(mocked_rmtree.mock_calls, [
            call(PosixPath('/game-instance'))
        ])
        self.assertEqual(mocked_run.mock_calls, [
            call(['mono', PosixPath('/ckan.exe'), 'instance', 'fake',
                  '--game', 'KSP',
                  '--set-default', '--headless', 'dummy',
                  PosixPath('/game-instance'), '1.8.1',
                  '--MakingHistory', '1.1.0', '--BreakingGround', '1.0.0'],
                 capture_output=True),
            call(['mono', PosixPath('/ckan.exe'), 'compat', 'add', '1.8.0'],
                 capture_output=True),
            call(['mono', PosixPath('/ckan.exe'), 'cache', 'set', PosixPath('/cache'), '--headless'],
                 capture_output=True),
            call(['mono', PosixPath('/ckan.exe'), 'cache', 'setlimit', '5000'],
                 capture_output=True),
            call(['mono', PosixPath('/ckan.exe'), 'repo', 'add',
                  'local', 'file:///repo/metadata.tar.gz'],
                 capture_output=True),
            call(['mono', PosixPath('/ckan.exe'), 'repo', 'priority',
                  'local', '0'],
                 capture_output=True),
            call(['mono', PosixPath('/ckan.exe'), 'update'],
                 capture_output=True),
            call(['mono', PosixPath('/ckan.exe'), 'instance', 'forget', 'dummy'],
                 capture_output=True)
        ])
