import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const sql = fs.readFileSync(path.join(__dirname, "_kankeishi_insert.sql"), "utf8");
const inserts = sql.split(/(?=INSERT INTO public\.knowledge)/).filter((s) => s.trim().startsWith("INSERT"));
const begin = "BEGIN;\n";
const commit = "COMMIT;\n";
const perBatch = 8;
for (let i = 0, b = 0; i < inserts.length; i += perBatch, b++) {
  const chunk = inserts.slice(i, i + perBatch);
  const isFirst = i === 0;
  const isLast = i + perBatch >= inserts.length;
  let out = isFirst ? begin : "";
  out += chunk.join("");
  if (isLast) out += commit;
  else out += ""; // middle batches need no commit
  fs.writeFileSync(path.join(__dirname, `_batch_${b}.sql`), out, "utf8");
  console.log("batch", b, "statements", chunk.length);
}
