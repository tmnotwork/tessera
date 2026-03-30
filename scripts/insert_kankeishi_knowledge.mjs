import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(__dirname, "..");
const MD = path.join(ROOT, "docs", "c.テキスト", "関係詞.md");
const OUT = path.join(__dirname, "_kankeishi_insert.sql");
const SUBJECT_ID = "72cba8cc-28b9-41fb-bf72-257a99139831";

function sqlStr(s) {
  return "'" + String(s).replace(/'/g, "''") + "'";
}

const text = fs.readFileSync(MD, "utf8");
const lines = text.split(/\r?\n/);
const sections = [];
let title = null;
let body = [];

function flush() {
  if (title === null) return;
  sections.push([title, body.join("\n").trim()]);
  body = [];
}

for (let i = 0; i < lines.length; i++) {
  const line = lines[i];
  if (line.startsWith("## ")) {
    flush();
    title = line.slice(3).trim();
    continue;
  }
  if (line.startsWith("# ") && !line.startsWith("## ")) {
    if (i === 0) continue;
    flush();
    title = line.slice(2).trim();
    continue;
  }
  if (title !== null) body.push(line);
}
flush();

let out = "BEGIN;\n";
let order = 1;
for (const [t, b] of sections) {
  out +=
    "INSERT INTO public.knowledge (subject_id, subject, unit, content, description, type, display_order, construction) VALUES (" +
    sqlStr(SUBJECT_ID) +
    "::uuid, " +
    sqlStr("英文法") +
    ", " +
    sqlStr("関係詞") +
    ", " +
    sqlStr(t) +
    ", " +
    sqlStr(b) +
    ", 'grammar', " +
    order +
    ", false);\n";
  order++;
}
out += "COMMIT;\n";
fs.writeFileSync(OUT, out, "utf8");
console.log("sections", sections.length, "bytes", Buffer.byteLength(out));
