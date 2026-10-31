#!/usr/bin/env python3
"""Adds DeletionPolicy/UpdateReplacePolicy: Retain to the resources of a CloudFormation template.

    add_retain.py FILE...           edit the files in place (keeps CRLF/LF line endings)
    add_retain.py --verify FILE     read a template from stdin and check that FILE's resources
                                    are all marked Retain in it (used on `aws cloudformation get-template`)

Lambda permissions are skipped on purpose: Terraform creates them fresh (new statement ids), so
CloudFormation may delete the old ones. Every other resource is kept in AWS and imported.
"""

import re
import sys

SKIP_TYPES = {"AWS::Lambda::Permission"}
HEADER = re.compile(r"^  ([A-Za-z0-9]+):\s*$")
TYPE = re.compile(r"^    Type:\s*(\S+)\s*$")


def resources(lines):
    """Yields (logical_id, type, type_line_index, block_end_index) for each resource."""
    in_resources = False
    found = []
    for i, line in enumerate(lines):
        if re.match(r"^[A-Za-z]", line):
            in_resources = line.strip() == "Resources:"
            continue
        if not in_resources:
            continue
        m = HEADER.match(line)
        if m:
            found.append([m.group(1), None, None, len(lines)])
            if len(found) > 1:
                found[-2][3] = i
            continue
        t = TYPE.match(line)
        if t and found and found[-1][1] is None:
            found[-1][1], found[-1][2] = t.group(1), i
    return [tuple(f) for f in found if f[1]]


def has(lines, start, end, key):
    return any(re.match(rf"^    {key}:\s*Retain\s*$", ln) for ln in lines[start:end])


def edit(path):
    raw = open(path, newline="").read()
    eol = "\r\n" if "\r\n" in raw else "\n"
    lines = raw.split(eol)
    # Insert from the bottom so earlier indexes stay valid.
    changed = []
    for logical, rtype, type_idx, end in reversed(resources(lines)):
        if rtype in SKIP_TYPES:
            continue
        add = [
            f"    {key}: Retain"
            for key in ("DeletionPolicy", "UpdateReplacePolicy")
            if not has(lines, type_idx, end, key)
        ]
        if add:
            lines[type_idx + 1 : type_idx + 1] = add
            changed.append(logical)
    open(path, "w", newline="").write(eol.join(lines))
    print(f"{path}: {len(changed)} resource(s) marked Retain" + (f" ({', '.join(reversed(changed))})" if changed else ""))


def verify(path, stored):
    expected = {
        logical
        for logical, rtype, _, _ in resources(open(path, newline="").read().splitlines())
        if rtype not in SKIP_TYPES
    }
    lines = stored.splitlines()
    ok = {
        logical
        for logical, _, start, end in resources(lines)
        if has(lines, start, end, "DeletionPolicy") and has(lines, start, end, "UpdateReplacePolicy")
    }
    missing = sorted(expected - ok)
    if missing:
        print(f"NOT retained in the deployed stack: {', '.join(missing)}")
        return 1
    print(f"ok: all {len(expected)} resources are Retain in the deployed stack")
    return 0


if __name__ == "__main__":
    args = sys.argv[1:]
    if len(args) == 2 and args[0] == "--verify":
        sys.exit(verify(args[1], sys.stdin.read()))
    if not args or args[0].startswith("-"):
        sys.exit(__doc__)
    for p in args:
        edit(p)
