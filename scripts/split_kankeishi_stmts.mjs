import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const all = fs.readFileSync(path.join(__dirname, "_kankeishi_insert.sql"), "utf8");
const body = all.replace(/^BEGIN;\r?\n/, "").replace(/\r?\nCOMMIT;\r?\n?$/, "");
const stmts = body.split(/\r?\n(?=INSERT INTO public\.knowledge)/).filter(Boolean);
const outDir = path.join(__dirname, "kankeishi_stmts");
fs.mkdirSync(outDir, { recursive: true });
stmts.forEach((s, i) => {
  fs.writeFileSync(path.join(outDir, `${String(i + 1).padStart(2, "0")}.sql`), s.trim() + "\n", "utf8");
});
console.log("count", stmts.length);
