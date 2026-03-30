import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(__dirname, "..");
const MD = path.join(ROOT, "docs", "c.テキスト", "関係詞.md");

const SUBJECT_ID = "72cba8cc-28b9-41fb-bf72-257a99139831";

function loadEnv() {
  const p = path.join(ROOT, ".env");
  const o = {};
  if (!fs.existsSync(p)) return o;
  for (const line of fs.readFileSync(p, "utf8").split(/\r?\n/)) {
    const m = line.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
    if (m) o[m[1]] = m[2].trim();
  }
  return o;
}

function parseSections() {
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
  return sections;
}

async function main() {
  const env = loadEnv();
  const url = env.SUPABASE_URL?.replace(/\/$/, "");
  const key = env.SUPABASE_ANON_KEY;
  if (!url || !key) {
    console.error("Missing SUPABASE_URL or SUPABASE_ANON_KEY in .env");
    process.exit(1);
  }

  const sections = parseSections();
  const rows = sections.map(([t, b], i) => ({
    subject_id: SUBJECT_ID,
    subject: "英文法",
    unit: "関係詞",
    content: t,
    description: b,
    type: "grammar",
    display_order: i + 1,
    construction: false,
  }));

  const headers = {
    apikey: key,
    Authorization: `Bearer ${key}`,
    "Content-Type": "application/json",
    Prefer: "return=minimal,resolution=merge-duplicates",
  };

  const delRes = await fetch(
    `${url}/rest/v1/knowledge?subject_id=eq.${SUBJECT_ID}&unit=eq.${encodeURIComponent("関係詞")}`,
    { method: "DELETE", headers: { ...headers, Prefer: "return=minimal" } }
  );
  if (!delRes.ok) {
    const t = await delRes.text();
    console.error("DELETE failed", delRes.status, t);
    process.exit(1);
  }

  const insRes = await fetch(`${url}/rest/v1/knowledge`, {
    method: "POST",
    headers,
    body: JSON.stringify(rows),
  });
  if (!insRes.ok) {
    const t = await insRes.text();
    console.error("POST failed", insRes.status, t);
    process.exit(1);
  }

  console.log("OK inserted", rows.length, "rows for unit 関係詞");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
