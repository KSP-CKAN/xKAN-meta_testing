import unittest

from ckan_meta_tester.ckan_meta_tester import CkanMetaTester


class TestCkanMetaTester(unittest.TestCase):

    def test_true(self) -> None:
        tester = CkanMetaTester(False)
        self.assertTrue(tester.test_metadata())

    def test_pr_body_tests(self) -> None:
        tester = CkanMetaTester(False)
        result = tester.pr_body_tests("""
        ## Description
        Basic test case

        ckan install Astrogator ModuleManager=4.2.1
        ckan compat add 1.12""")

        self.assertListEqual(next(iter(result)), ["Astrogator", "ModuleManager=4.2.1"])
