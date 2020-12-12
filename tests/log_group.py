from io import StringIO
from unittest import TestCase
from unittest.mock import patch

from ckan_meta_tester.log_group import LogGroup


class TestLogGroup(TestCase):

    # This lets us capture stdout and return it as a string
    @patch('sys.stdout', new_callable=StringIO)
    def use_log_group(self, header: str, body: str, mock_stdout: StringIO) -> str:
        with LogGroup(header):
            print(body)
        return mock_stdout.getvalue()

    def test_log_group_output(self) -> None:
        # Arrange
        hdr  = 'Test Header'
        body = 'Test body\nLine 2'

        # Arrange / Act
        str = self.use_log_group(hdr, body)

        # Assert
        self.assertEqual(str, '\n'.join(['::group::Test Header',
                                         'Test body',
                                         'Line 2',
                                         '::endgroup::',
                                         '']))
