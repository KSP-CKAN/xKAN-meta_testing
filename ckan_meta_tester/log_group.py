from types import TracebackType
from typing import Type


class LogGroup:

    def __init__(self, title: str) -> None:
        self.title = title
        # Inner messages can sneak in front of us if we do this in __enter__
        print(f'::group::{self.title}', flush=True)

    def __enter__(self) -> 'LogGroup':
        return self

    def __exit__(self, exc_type: Type[BaseException],
                 exc_value: BaseException, traceback: TracebackType) -> None:
        print('::endgroup::', flush=True)
