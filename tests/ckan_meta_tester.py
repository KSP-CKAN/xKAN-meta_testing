import unittest

from ckan_meta_tester.ckan_meta_tester import CkanMetaTester


class TestCkanMetaTester(unittest.TestCase):

    def test_true(self) -> None:
        tester = CkanMetaTester()
        self.assertTrue(tester.test_metadata())
