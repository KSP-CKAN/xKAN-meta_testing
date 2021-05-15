#!/usr/bin/env python

from setuptools import setup, find_packages

setup(
    name='CkanMetaTester',
    version='0.1',
    description='Testing Framework for Validating ckans/netkans',
    author='Leon Wright',
    author_email='techman83@gmail.com',
    package_data={
        "": ["*.txt"],
    },
    entry_points={
        'console_scripts': [
            'ckanmetatester=ckan_meta_tester:test_metadata',
        ],
    },
    packages=find_packages(),
    install_requires=[
        'gitpython',
        'exitstatus',
        'requests',
        'demjson',
        'yamllint',
    ],
    extras_require={
        'development': [
            'pylint',
            'autopep8',
            'mypy',
        ]
    },
)
