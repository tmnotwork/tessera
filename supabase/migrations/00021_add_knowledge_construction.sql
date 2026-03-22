-- 知識カード「構文」フラグ（UI の Chip / knowledge.json の construction と同期）
ALTER TABLE public.knowledge
  ADD COLUMN IF NOT EXISTS construction BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN public.knowledge.construction IS '構文カード。knowledge.json の construction と AssetImport で同期する。';
