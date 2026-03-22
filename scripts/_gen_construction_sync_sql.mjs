import fs from "fs";

const j = JSON.parse(fs.readFileSync("assets/knowledge.json", "utf8"));
function esc(s) {
  return String(s).replace(/'/g, "''");
}
const rows = j.map((e) => {
  const title = esc(e.title ?? "");
  const topic = (e.topic ?? "").trim();
  const unit = topic === "" ? "NULL" : `'${esc(topic)}'`;
  const c = e.construction === true || e.construction === 1 ? "true" : "false";
  return `('${title}', ${unit}::text, ${c})`;
});
const values = rows.join(",\n");
const sql = `UPDATE public.knowledge AS k
SET construction = d.flag
FROM (
VALUES
${values}
) AS d(title_txt, unit_txt, flag)
WHERE k.subject_id = (SELECT id FROM public.subjects WHERE name = '英文法' LIMIT 1)
  AND k.content = d.title_txt
  AND (k.unit IS NOT DISTINCT FROM d.unit_txt);
`;
fs.writeFileSync("scripts/_sync_construction_from_json.sql", sql, "utf8");
console.log("Wrote scripts/_sync_construction_from_json.sql");
