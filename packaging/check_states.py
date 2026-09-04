#!/usr/bin/env python3
"""Fail if the two halves of the state vocabulary have drifted apart.

stems/states.py and shared/States.swift declare the same states in two
languages, and the server sends those strings to two apps that switch on them.
A case added to one and forgotten in the other is not a compile error
anywhere: it is a row that silently stops decoding, or a state that renders as
nothing. So it is checked here instead.

    python3 packaging/check_states.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from stems.states import Failure, Stage, WorkerState  # noqa: E402

SWIFT = ROOT / "shared" / "States.swift"


def swift_cases(source: str, enum: str) -> set[str]:
    """The raw values declared by one Swift enum.

    Only the declarations at the top of the body: everything after the first
    `var`, `func` or `static` is behaviour, and the `case` lines inside a
    switch there are not cases of the enum.
    """
    body = re.search(rf"enum {enum}: String[^{{]*{{(.*?)\n}}", source, re.S)
    if not body:
        raise SystemExit(f"no enum {enum} in States.swift")

    found = set()
    for line in body.group(1).splitlines():
        line = line.strip()
        if line.startswith(("var ", "func ", "static ")):
            break
        if not line.startswith("case "):
            continue
        for part in line[5:].split(","):
            part = part.strip()
            if not part:
                continue
            if "=" in part:
                found.add(part.split("=", 1)[1].strip().strip('"'))
            else:
                # A bare case's raw value is its own name.
                found.add(part)
    return found


def main() -> int:
    source = SWIFT.read_text()
    problems = []
    for enum, name in ((Stage, "Stage"), (WorkerState, "WorkerState"),
                       (Failure, "Failure")):
        python = {member.value for member in enum}
        swift = swift_cases(source, name)
        for missing in sorted(python - swift):
            problems.append(f"{name}.{missing} is in Python but not Swift")
        for extra in sorted(swift - python):
            problems.append(f"{name}.{extra} is in Swift but not Python")
        if not (python - swift or swift - python):
            print(f"  {name}: {len(python)} states, both sides agree")

    for problem in problems:
        print(f"  MISMATCH: {problem}")
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
