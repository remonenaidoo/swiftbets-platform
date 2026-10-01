#!/usr/bin/env python3
"""Merges Cobertura reports per assembly, writes a Markdown summary and fails when an assembly is under its floor.

Usage: check-coverage.py FLOORS_JSON REPORT...
FLOORS_JSON maps an assembly name to {"line": pct, "branch": pct}; either key may be omitted.
"""

import json
import re
import sys
import xml.etree.ElementTree as ET

CONDITION = re.compile(r"\((\d+)/(\d+)\)")


def merge(paths):
    # (assembly, file, line) -> [hits, branches covered, branches total]
    lines = {}
    for path in paths:
        root = ET.parse(path).getroot()
        for package in root.iter("package"):
            assembly = package.get("name")
            if assembly.endswith("Tests"):
                continue
            for cls in package.iter("class"):
                filename = cls.get("filename")
                for line in cls.iter("line"):
                    key = (assembly, filename, int(line.get("number")))
                    entry = lines.setdefault(key, [0, 0, 0])
                    entry[0] = max(entry[0], int(line.get("hits", "0")))
                    match = CONDITION.search(line.get("condition-coverage", ""))
                    if match:
                        entry[1] = max(entry[1], int(match.group(1)))
                        entry[2] = max(entry[2], int(match.group(2)))
    totals = {}
    for (assembly, _, _), (hits, covered, total) in lines.items():
        t = totals.setdefault(assembly, [0, 0, 0, 0])
        t[0] += 1 if hits > 0 else 0
        t[1] += 1
        t[2] += covered
        t[3] += total
    return totals


def pct(covered, valid):
    return 100.0 if valid == 0 else 100.0 * covered / valid


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    floors = json.loads(argv[0] or "{}")
    totals = merge(argv[1:])
    failures = []
    print("| Assembly | Line % | Branch % | Floor |")
    print("|---|---:|---:|---|")
    for assembly in sorted(totals):
        lc, lv, bc, bv = totals[assembly]
        line, branch = pct(lc, lv), pct(bc, bv)
        floor = floors.get(assembly, {})
        marks = []
        for kind, actual in (("line", line), ("branch", branch)):
            if kind in floor:
                ok = actual + 1e-9 >= floor[kind]
                marks.append(f"{kind} {floor[kind]}% {'ok' if ok else 'FAIL'}")
                if not ok:
                    failures.append(f"{assembly}: {kind} {actual:.1f}% < {floor[kind]}%")
        print(f"| {assembly} | {line:.1f} | {branch:.1f} | {', '.join(marks)} |")
    missing = sorted(set(floors) - set(totals))
    failures += [f"{a}: no coverage reported" for a in missing]
    for failure in failures:
        print(f"::error::coverage floor: {failure}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
