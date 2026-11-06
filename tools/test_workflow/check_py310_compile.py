#!/usr/bin/env python3
"""
Does every tracked .py file compile on Python 3.10?

[Co-developed with claude code -- Adam]

Why 3.10: tracked Python must not use syntax newer than 3.10. The CI test job runs 3.12, which
accepts syntax older interpreters reject (for example a line break inside the braces of a quoted
f-string, PEP 701), and code here also runs on older ones: the SDK declares requires-python >= 3.10
(sdk/python/pyproject.toml), and the Ryu lane runs 3.8. This compiles every tracked .py with 3.10,
without running any of the code; it does not check 3.8. A newer interpreter would accept those
files, so the program refuses to run on anything but 3.10 (exit 2) rather than report a pass it
cannot back.

Usage (run it with the 3.10 interpreter):
    git ls-files -z -- '*.py' | python tools/test_workflow/check_py310_compile.py

Reads NUL-separated paths on stdin and compiles each from source in memory (no .pyc is written).
Prints one "path:line: message" line per failure and then a count; exits 1 if any file failed.
Exits 2, checking nothing, on a wrong interpreter version or when no path is given (an empty list
would otherwise read as "0 failed").
"""
import sys


def main() -> int:
    if sys.version_info[:2] != (3, 10):
        print(f"refusing to run on python {sys.version.split()[0]}: only 3.10 can tell whether "
              "a file compiles on 3.10; run it with a 3.10 interpreter")
        return 2
    paths = [p for p in sys.stdin.buffer.read().split(b"\0") if p]
    if not paths:
        print("no paths given on stdin; call it as: "
              "git ls-files -z -- '*.py' | python tools/test_workflow/check_py310_compile.py")
        return 2
    failed = 0
    for raw in paths:
        path = raw.decode("utf-8", "surrogateescape")
        try:
            with open(path, "rb") as f:
                source = f.read()
            compile(source, path, "exec", dont_inherit=True)
        except SyntaxError as e:
            failed += 1
            print(f"{path}:{e.lineno or 0}: {e.msg}")
        except (OSError, ValueError, MemoryError, RecursionError) as e:
            failed += 1
            print(f"{path}:0: {type(e).__name__}: {e}")
    print(f"checked {len(paths)} files, {failed} failed (python {sys.version.split()[0]})")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
