"""Diff the window lines of two consumer logs (lateness 120 s vs 0 s, same data)."""
import re
import sys

LINE = re.compile(r"window (\d\d:\d\d)\s+(.*)")
CELL = re.compile(r"(\w+) (\d+)/(\d+)=")


def load(path):
    out = {}
    for line in open(path, encoding="utf-8"):
        m = LINE.search(line)
        if m:
            out[m.group(1)] = {c[0]: (int(c[1]), int(c[2])) for c in CELL.findall(m.group(2))}
    return out


a, b = load(sys.argv[1]), load(sys.argv[2])
changed, lost_outcomes, lost_failures = 0, 0, 0
print("window  method      lateness120  lateness0")
for w in sorted(set(a) & set(b)):
    for method in sorted(set(a[w]) | set(b[w])):
        fa, na = a[w].get(method, (0, 0))
        fb, nb = b[w].get(method, (0, 0))
        if (fa, na) != (fb, nb):
            changed += 1
            lost_outcomes += na - nb
            lost_failures += fa - fb
            if changed <= 25:
                print(f"{w}   {method:<10}  {fa:>3}/{na:<3}={fa/na if na else 0:>4.0%}    {fb:>3}/{nb:<3}={fb/nb if nb else 0:>4.0%}")
cells = sum(len(v) for w, v in a.items() if w in b)
print(f"\ncommon windows {len(set(a) & set(b))}, cells changed {changed} of {cells}, "
      f"outcomes missing with lateness 0: {lost_outcomes} (of which failures {lost_failures})")
