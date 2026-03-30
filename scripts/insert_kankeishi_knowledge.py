# One-off: parse docs/c.テキスト/関係詞.md into knowledge rows (UTF-8).
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MD = ROOT / "docs" / "c.テキスト" / "関係詞.md"
SUBJECT_ID = "72cba8cc-28b9-41fb-bf72-257a99139831"


def sql_str(s: str) -> str:
    return "'" + s.replace("'", "''") + "'"


def parse_sections(text: str) -> list[tuple[str, str]]:
    lines = text.splitlines()
    sections: list[tuple[str, str]] = []
    current_title: str | None = None
    current_body: list[str] = []
    first_line_done = False

    def flush():
        nonlocal current_title, current_body
        if current_title is None:
            return
        body = "\n".join(current_body).strip()
        sections.append((current_title, body))
        current_body = []

    for i, line in enumerate(lines):
        if line.startswith("## "):
            flush()
            current_title = line[3:].strip()
            first_line_done = True
            continue
        if line.startswith("# ") and not line.startswith("## "):
            if i == 0:
                first_line_done = True
                continue
            flush()
            current_title = line[2:].strip()
            first_line_done = True
            continue
        if current_title is not None:
            current_body.append(line)
    flush()
    return sections


def main() -> None:
    text = MD.read_text(encoding="utf-8")
    sections = parse_sections(text)
    if not sections:
        print("No sections", file=sys.stderr)
        sys.exit(1)

    stmts = [
        "BEGIN;",
        "-- 関係詞チャプター知識カード",
    ]
    for order, (title, body) in enumerate(sections, start=1):
        stmts.append(
            "INSERT INTO public.knowledge (subject_id, subject, unit, content, description, type, display_order, construction) "
            f"VALUES ({sql_str(SUBJECT_ID)}::uuid, {sql_str('英文法')}, {sql_str('関係詞')}, "
            f"{sql_str(title)}, {sql_str(body)}, 'grammar', {order}, false);"
        )
    stmts.append("COMMIT;")
    print("\n".join(stmts))


if __name__ == "__main__":
    main()
