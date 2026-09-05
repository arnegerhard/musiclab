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


def emitted_event_kinds() -> set[str]:
    """Every `kind=` the pipeline announces, found in the source.

    Cheap and literal on purpose: the point is to notice a new event that
    nobody taught the interpreter about, which is how "Separating the stems"
    came to never appear.
    """
    # `done` is the pipeline saying it has finished, which its caller acts on
    # by using the result; there is nothing to display for it. recompress is a
    # command line tool with its own events and no job behind them.
    handled_elsewhere = {"done"}
    ignore_files = {"progress.py", "server.py", "agent.py", "recompress.py"}

    kinds = set()
    for path in (ROOT / "stems").glob("*.py"):
        if path.name in ignore_files:
            continue
        for match in re.finditer(r'kind="([a-z_]+)"', path.read_text()):
            kinds.add(match.group(1))
    return kinds - handled_elsewhere


def check_events() -> list[str]:
    from stems.progress import interpret

    # Enough of a payload that a mapping can compute a fraction from it.
    sample = {"fraction": 0.5, "index": 0, "total": 2, "done": 1,
              "model": "m", "title": "t", "stage": "s", "reason": "r",
              "stems": ["a"], "file": "f", "megabytes": 1.0}
    problems = []
    for kind in sorted(emitted_event_kinds()):
        if interpret({**sample, "kind": kind}) is None:
            problems.append(f"the pipeline emits {kind!r} and nothing reads it")
    print(f"  events: {len(emitted_event_kinds())} emitted, "
          f"{len(emitted_event_kinds()) - len(problems)} understood")
    return problems


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

    problems += check_events()

    for problem in problems:
        print(f"  MISMATCH: {problem}")
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
