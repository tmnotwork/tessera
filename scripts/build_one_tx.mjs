import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
let q = "BEGIN;\n";
for (let i = 1; i <= 28; i++) {
  const j = JSON.parse(fs.readFileSync(path.join(__dirname, "mcp_args", `${String(i).padStart(2, "0")}.json`), "utf8"));
  q += j.query.trim() + "\n";
}
q += "COMMIT;";
const out = path.join(__dirname, "_one_tx.sql");
fs.writeFileSync(out, q, "utf8");
console.log("bytes", Buffer.byteLength(q));
