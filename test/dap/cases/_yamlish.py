"""Minimal YAML-subset parser for GitHub workflow files (not a case).

Handles exactly the constructs used in .github/workflows/*.yml here:
mappings, nested mappings, block sequences (including the ``key:`` /
``- item`` same-indent style), lists of inline single-pair maps
(``- uses: actions/checkout@v4``), literal block scalars (``run: |``),
comments, and quoted scalars. Anything fancier raises ValueError instead
of misparsing.
"""

from __future__ import annotations


def _significant_lines(text: str):
    out = []
    for raw in text.splitlines():
        if not raw.strip() or raw.strip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        if "\t" in raw[:indent]:
            raise ValueError("tab indentation not supported")
        out.append((indent, raw.strip()))
    return out


def parse(text: str):
    lines = _significant_lines(text)
    root: dict = {}
    # stack of (indent, container); containers are dict or list.
    # A block sequence opened by `key:` with `- ` items at the SAME indent
    # as the key is pushed with that same indent; the pop rule below keeps
    # `- ` lines attached to a list at equal indent.
    stack: list[tuple[int, object]] = [(-1, root)]
    i = 0
    n = len(lines)
    while i < n:
        indent, stripped = lines[i]
        is_item = stripped.startswith("- ")
        while stack:
            top_indent, top = stack[-1]
            if top_indent < indent:
                break
            if top_indent == indent and is_item and isinstance(top, list):
                break
            stack.pop()
        parent = stack[-1][1]

        if is_item:
            if not isinstance(parent, list):
                raise ValueError("list item outside list at: %r" % stripped)
            item = stripped[2:].strip()
            if ": " in item or item.endswith(":"):
                # inline single-pair map: `- uses: actions/checkout@v4`
                k, v = item.split(":", 1)
                d = {k.strip(): v.strip().strip("'\"")}
                parent.append(d)
                stack.append((indent, d))
            else:
                parent.append(item.strip("'\""))
            i += 1
            continue

        if ":" not in stripped:
            raise ValueError("cannot parse line: %r" % stripped)
        key, _, value = stripped.partition(":")
        key = key.strip()
        value = value.strip()
        if value in ("|", ">"):
            # literal/folded block scalar: consume more-indented lines
            i += 1
            buf = []
            while i < n and lines[i][0] > indent:
                buf.append(lines[i][1])
                i += 1
            if not isinstance(parent, dict):  # pragma: no cover
                raise ValueError("block scalar outside mapping")
            parent[key] = "\n".join(buf)
            continue
        if value:
            if not isinstance(parent, dict):  # pragma: no cover
                raise ValueError("scalar outside mapping")
            parent[key] = value.strip("'\"")
            i += 1
            continue
        # Empty value: nested block, list, or null.
        j = i + 1
        while j < n and lines[j][0] < indent:
            j += 1
        if not isinstance(parent, dict):  # pragma: no cover
            raise ValueError("nested block outside mapping")
        if j >= n:
            parent[key] = None
            i += 1
            continue
        child_indent, child_line = lines[j]
        if child_line.startswith("- ") and child_indent >= indent:
            # Block sequence: either nested deeper or the same-indent
            # `key:` / `- item` style. Both attach to this key.
            child = []
        elif child_indent > indent:
            child = {}
        else:
            # Next line is a dedent: null value.
            parent[key] = None
            i += 1
            continue
        parent[key] = child
        stack.append((indent, child))
        i += 1
    return root


def workflow_steps(doc: dict) -> list[dict]:
    """Ordered step dicts across all jobs in a workflow document."""
    steps: list[dict] = []
    jobs = doc.get("jobs") or {}
    for _job_name, job in jobs.items():
        if isinstance(job, dict):
            for step in job.get("steps") or []:
                if isinstance(step, dict):
                    steps.append(step)
    return steps


def step_text(step: dict) -> str:
    return " ".join(str(step.get(k, "")) for k in ("name", "run", "uses")).lower()
