"""Mirror fallback: try a primary URL, fall back to each mirror in turn."""

from __future__ import annotations

from typing import Callable, Iterable, List, Optional, TypeVar

T = TypeVar("T")


class MirrorFallbackError(RuntimeError):
    """Raised when every URL in a primary+mirrors list fails to open."""

    def __init__(self, urls: List[str], errors: List[BaseException]) -> None:
        self.urls = urls
        self.errors = errors
        joined = "; ".join(f"{u}: {type(e).__name__}: {e}" for u, e in zip(urls, errors))
        super().__init__(f"all {len(urls)} source URLs failed ({joined})")


def open_with_fallback(
    urls: Iterable[str],
    opener: Callable[[str], T],
    *,
    expected_errors: Optional[tuple] = None,
) -> T:
    """Try each URL in order, returning the first successful ``opener(url)``.

    ``opener`` is called with each URL in turn; the first non-raising call's
    return value is returned. ``expected_errors`` restricts which exception
    types count as a fallback trigger — anything else propagates immediately.
    Defaults to catching ``OSError`` and ``RuntimeError``.
    """
    if expected_errors is None:
        expected_errors = (OSError, RuntimeError)
    tried: List[str] = []
    errors: List[BaseException] = []
    for url in urls:
        tried.append(url)
        try:
            return opener(url)
        except expected_errors as exc:
            errors.append(exc)
            continue
    raise MirrorFallbackError(tried, errors)
