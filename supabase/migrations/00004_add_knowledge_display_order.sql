-- 知識一覧の表示順（unit 内の並び）用
ALTER TABLE public.knowledge
  ADD COLUMN IF NOT EXISTS display_order INT;

COMMENT ON COLUMN public.knowledge.display_order IS 'unit 内の表示順。NULL は最後にソートされる。';
