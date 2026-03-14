-- ============================================================
-- 知識カード用タグ（RDB・中間テーブル方式：暗記カードと同じ構成）
-- ============================================================

-- タグマスタ（名前は全局でユニーク）
CREATE TABLE IF NOT EXISTS public.knowledge_tags (
  id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL UNIQUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.knowledge_tags IS '知識カード用タグマスタ';

-- 中間テーブル: 知識カード ⇔ タグ（多対多）
CREATE TABLE IF NOT EXISTS public.knowledge_card_tags (
  knowledge_id UUID NOT NULL REFERENCES public.knowledge(id) ON DELETE CASCADE,
  tag_id       UUID NOT NULL REFERENCES public.knowledge_tags(id) ON DELETE CASCADE,
  PRIMARY KEY (knowledge_id, tag_id)
);

CREATE INDEX IF NOT EXISTS ix_knowledge_card_tags_tag_id
  ON public.knowledge_card_tags(tag_id);

COMMENT ON TABLE public.knowledge_card_tags IS '知識カードとタグの中間テーブル（多対多）';

-- 既存の knowledge.tags カラム（JSONB）があればデータを移行してから削除
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'knowledge' AND column_name = 'tags'
  ) THEN
    INSERT INTO public.knowledge_tags (name)
    SELECT DISTINCT jsonb_array_elements_text(k.tags)::text
    FROM public.knowledge k
    WHERE k.tags IS NOT NULL AND jsonb_typeof(k.tags) = 'array'
    ON CONFLICT (name) DO NOTHING;

    INSERT INTO public.knowledge_card_tags (knowledge_id, tag_id)
    SELECT k.id, t.id
    FROM public.knowledge k
    CROSS JOIN LATERAL jsonb_array_elements_text(k.tags) AS tag_name(text)
    JOIN public.knowledge_tags t ON t.name = tag_name
    WHERE k.tags IS NOT NULL AND jsonb_typeof(k.tags) = 'array';

    ALTER TABLE public.knowledge DROP COLUMN tags;
  END IF;
END $$;

-- RLS
ALTER TABLE public.knowledge_tags ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.knowledge_card_tags ENABLE ROW LEVEL SECURITY;

CREATE POLICY "knowledge_tags: anon select"
  ON public.knowledge_tags FOR SELECT TO anon USING (true);
CREATE POLICY "knowledge_tags: anon insert"
  ON public.knowledge_tags FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY "knowledge_tags: anon update"
  ON public.knowledge_tags FOR UPDATE TO anon USING (true) WITH CHECK (true);
CREATE POLICY "knowledge_tags: anon delete"
  ON public.knowledge_tags FOR DELETE TO anon USING (true);

CREATE POLICY "knowledge_card_tags: anon select"
  ON public.knowledge_card_tags FOR SELECT TO anon USING (true);
CREATE POLICY "knowledge_card_tags: anon insert"
  ON public.knowledge_card_tags FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY "knowledge_card_tags: anon update"
  ON public.knowledge_card_tags FOR UPDATE TO anon USING (true) WITH CHECK (true);
CREATE POLICY "knowledge_card_tags: anon delete"
  ON public.knowledge_card_tags FOR DELETE TO anon USING (true);
