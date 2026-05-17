#!/usr/bin/env python3
"""
resume_eval.py — Resume an interrupted Promptfoo redteam eval.

Reads ~/.promptfoo/promptfoo.db to find which prompts already have valid
(non-empty) outputs. Writes a new YAML containing only the tests that
haven't completed successfully yet.

After the server is restarted with fixed params (see start_server.sh),
run this script, then eval the generated resume YAML:

    python3 scripts/resume_eval.py --input output/english_results.json
    promptfoo eval --config output/english_results_resume.yaml

The resume YAML is self-contained (no YAML anchors) so it can be run
independently of the original generated file.
"""

import argparse
import json
import os
import re
import sqlite3
from pathlib import Path

DB_PATH = os.path.expanduser("~/.promptfoo/promptfoo.db")
MIN_VALID_OUTPUT = 20  # chars; shorter = context-overflow empty response


# ---------------------------------------------------------------------------
# DB helpers
# ---------------------------------------------------------------------------

def get_valid_prompts(db_path: str, min_valid: int = MIN_VALID_OUTPUT) -> set[str]:
    """Return normalised prompt strings that already have non-empty outputs."""
    conn = sqlite3.connect(db_path)
    c = conn.cursor()
    c.execute("SELECT test_case, response FROM eval_results WHERE response IS NOT NULL")
    valid: set[str] = set()
    for tc_raw, resp_raw in c.fetchall():
        try:
            output = str(json.loads(resp_raw).get("output", ""))
            if len(output) < min_valid:
                continue
            tc = json.loads(tc_raw)
            prompt = tc.get("vars", {}).get("prompt", "").strip()
            if prompt:
                valid.add(_norm(prompt))
        except Exception:
            pass
    conn.close()
    return valid


def _norm(text: str) -> str:
    """Normalise whitespace for prompt matching."""
    return re.sub(r"\s+", " ", text).strip()


# ---------------------------------------------------------------------------
# YAML parser — line-by-line state machine
# No external libs needed; handles >- folded scalars and nested indentation.
# ---------------------------------------------------------------------------

def _fold(lines: list[str]) -> str:
    """Collapse a >- folded YAML scalar (list of continuation lines) to a string."""
    return " ".join(line.strip() for line in lines if line.strip())


def extract_test_cases(yaml_path: str) -> list[dict]:
    """
    Parse Promptfoo-generated redteam YAML and return a list of test dicts:
        {
            "prompt":    str,
            "assert":    list[dict],      # [{type, metric, ...}, ...]
            "metadata":  dict,
        }
    Works without pyyaml by walking lines and tracking indent levels.
    """
    with open(yaml_path) as f:
        lines = f.readlines()

    # Find where 'tests:' begins
    tests_line = next((i for i, l in enumerate(lines) if l.rstrip() == "tests:"), None)
    if tests_line is None:
        raise ValueError("No 'tests:' section found")

    tests: list[dict] = []
    current: dict | None = None
    state = None          # 'prompt' | 'assert_type' | 'metadata_key' | None
    indent_stack: list[int] = []
    assert_entry: dict = {}
    fold_lines: list[str] = []
    fold_target: dict | None = None
    fold_key: str = ""
    metadata_key: str = ""

    def flush_fold():
        nonlocal fold_lines, fold_target, fold_key
        if fold_target is not None and fold_lines:
            fold_target[fold_key] = _fold(fold_lines)
        fold_lines = []
        fold_target = None
        fold_key = ""

    for raw in lines[tests_line + 1:]:
        line = raw.rstrip()
        if not line:
            continue

        indent = len(line) - len(line.lstrip())
        stripped = line.strip()

        # Strip YAML anchors and aliases from keys/values
        # e.g.  "vars: &ref_12"  →  "vars: "
        #        "modifiers: *ref_1"  →  "modifiers: {}"
        stripped_clean = re.sub(r"&ref_\d+", "", stripped).strip()
        stripped_clean = re.sub(r":\s*\*ref_\d+\s*$", ": {}", stripped_clean)
        stripped_clean = re.sub(r"^\*ref_\d+\s*$", "{}", stripped_clean)

        # New top-level test case: "  - vars:"  (indent=2)
        if indent == 2 and stripped_clean.startswith("- vars:"):
            flush_fold()
            if current is not None:
                tests.append(current)
            current = {"prompt": "", "assert": [], "metadata": {}}
            assert_entry = {}
            state = None
            indent_stack = [2]
            continue

        if current is None:
            continue

        # Handle folded scalar continuation
        if fold_target is not None:
            if indent > (indent_stack[-1] if indent_stack else 0):
                fold_lines.append(stripped_clean)
                continue
            else:
                flush_fold()

        # prompt field
        if indent == 6 and stripped_clean.startswith("prompt:"):
            val = stripped_clean[len("prompt:"):].strip()
            if val in (">-", ">", "|", "|-"):
                fold_target = current
                fold_key = "prompt"
                fold_lines = []
            else:
                # inline value — strip quotes
                current["prompt"] = val.strip('"\'')
            indent_stack = [2, 4, 6]
            state = "prompt"
            continue

        # assert block
        if indent == 4 and stripped_clean == "assert:":
            indent_stack = [2, 4]
            state = "assert"
            continue

        if state == "assert":
            if indent == 6 and stripped_clean.startswith("- type:"):
                flush_fold()
                assert_entry = {"type": stripped_clean[len("- type:"):].strip()}
                current["assert"].append(assert_entry)
            elif indent == 8 and stripped_clean.startswith("metric:"):
                assert_entry["metric"] = stripped_clean[len("metric:"):].strip()
            elif indent == 6 and stripped_clean.startswith("- id:"):
                assert_entry = {"id": stripped_clean[len("- id:"):].strip()}
                current["assert"].append(assert_entry)

        # metadata block
        if indent == 4 and stripped_clean == "metadata:":
            state = "metadata"
            indent_stack = [2, 4]
            continue

        if state == "metadata" and indent == 6:
            if ":" in stripped_clean:
                k, _, v = stripped_clean.partition(":")
                v = v.strip()
                if v in (">-", ">"):
                    fold_target = current["metadata"]
                    fold_key = k.strip()
                    fold_lines = []
                elif v and not v.startswith("&") and not v.startswith("*"):
                    current["metadata"][k.strip()] = v.strip('"\'')

    flush_fold()
    if current is not None:
        tests.append(current)
    return tests


# ---------------------------------------------------------------------------
# Resume YAML writer
# ---------------------------------------------------------------------------

def _yaml_str(s: str) -> str:
    """Emit a YAML string value, using block scalar for multilines."""
    if "\n" in s or len(s) > 80:
        # Use literal block
        indented = "\n".join("        " + l for l in s.splitlines())
        return "|-\n" + indented
    # Quote if contains YAML special chars
    if any(c in s for c in ":#{}[]|>&*!,'\""):
        escaped = s.replace("\\", "\\\\").replace('"', '\\"')
        return f'"{escaped}"'
    return s


def build_resume_yaml(tests: list[dict], source_yaml: str) -> str:
    """Build a clean YAML string for the resume run (no anchors)."""
    # Extract header (everything before 'tests:') from source
    with open(source_yaml) as f:
        content = f.read()
    tests_idx = content.find("\ntests:")
    header = content[:tests_idx] if tests_idx != -1 else ""

    # Remove description comment block (has stale generation timestamp)
    header = re.sub(r"^# ={10,}.*?# ={10,}\n", "", header, flags=re.DOTALL | re.MULTILINE)

    # Ensure max_tokens is present in targets config (needed for reasoning models
    # to cap thinking tokens and leave room for actual response)
    if "max_tokens:" not in header:
        header = header.replace(
            "      apiKey: dummy",
            "      apiKey: dummy\n      max_tokens: 2048",
        )

    lines = [header.rstrip(), "", "tests:"]
    for t in tests:
        prompt_val = _yaml_str(t["prompt"])
        lines.append(f"  - vars:")
        lines.append(f"      prompt: {prompt_val}")
        lines.append(f"    assert:")
        for a in t["assert"]:
            if "type" in a:
                lines.append(f"      - type: {a['type']}")
                if "metric" in a:
                    lines.append(f"        metric: {a['metric']}")
        if t["metadata"]:
            lines.append(f"    metadata:")
            for k, v in t["metadata"].items():
                lines.append(f"      {k}: {_yaml_str(str(v))}")
    lines.append("")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description="Build resume YAML for interrupted Promptfoo eval")
    ap.add_argument("--input", required=True,
                    help="Generated redteam YAML (e.g. output/english_results.json)")
    ap.add_argument("--output", default=None,
                    help="Output path (default: <input>_resume.yaml)")
    ap.add_argument("--db", default=DB_PATH,
                    help=f"Promptfoo DB path (default: {DB_PATH})")
    ap.add_argument("--min-output", type=int, default=MIN_VALID_OUTPUT,
                    help="Min output chars to consider a test done (default: 20)")
    ap.add_argument("--list-remaining", action="store_true",
                    help="Just print remaining prompts, don't write file")
    args = ap.parse_args()

    min_valid = args.min_output

    if args.output is None:
        stem = Path(args.input).stem
        args.output = str(Path(args.input).parent / f"{stem}_resume.yaml")

    print(f"Reading DB: {args.db}")
    valid = get_valid_prompts(args.db, min_valid)
    print(f"  Valid completed prompts: {len(valid)}")

    print(f"Parsing tests from: {args.input}")
    all_tests = extract_test_cases(args.input)
    print(f"  Total test cases: {len(all_tests)}")

    remaining = [t for t in all_tests if _norm(t["prompt"]) not in valid]
    done = len(all_tests) - len(remaining)
    print(f"  Already done (with valid output): {done}")
    print(f"  Remaining: {len(remaining)}")

    if args.list_remaining:
        for t in remaining:
            plugin = t["metadata"].get("pluginId", "?")
            print(f"  [{plugin}] {t['prompt'][:80]}")
        return

    if not remaining:
        print("\nAll tests complete. Run: promptfoo redteam report")
        return

    yaml_out = build_resume_yaml(remaining, args.input)
    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    with open(args.output, "w") as f:
        f.write(yaml_out)

    print(f"\nResume YAML written: {args.output}")
    print(f"\nNext steps:")
    print(f"  1. Restart server:  ./start_server.sh")
    print(f"  2. Run resume eval: promptfoo eval --config {args.output}")
    print(f"  3. View report:     promptfoo redteam report")


if __name__ == "__main__":
    main()
