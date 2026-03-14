-- ============================================================
-- 暗記カード用タグ（RDB・中間テーブル方式）
-- ============================================================

-- タグマスタ（名前は全局でユニーク）
CREATE TABLE IF NOT EXISTS public.memorization_tags (
  id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL UNIQUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.memorization_tags IS '暗記カード用タグマスタ';

-- 中間テーブル: 暗記カード ⇔ タグ（多対多）
CREATE TABLE IF NOT EXISTS public.memorization_card_tags (
  memorization_card_id UUID NOT NULL REFERENCES public.memorization_cards(id) ON DELETE CASCADE,
  tag_id               UUID NOT NULL REFERENCES public.memorization_tags(id) ON DELETE CASCADE,
  PRIMARY KEY (memorization_card_id, tag_id)
);

CREATE INDEX IF NOT EXISTS ix_memorization_card_tags_tag_id
  ON public.memorization_card_tags(tag_id);

COMMENT ON TABLE public.memorization_card_tags IS '暗記カードとタグの中間テーブル（多対多）';

-- RLS
ALTER TABLE public.memorization_tags ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.memorization_card_tags ENABLE ROW LEVEL SECURITY;

CREATE POLICY "memorization_tags: anon select"
  ON public.memorization_tags FOR SELECT TO anon USING (true);
CREATE POLICY "memorization_tags: anon insert"
  ON public.memorization_tags FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY "memorization_tags: anon update"
  ON public.memorization_tags FOR UPDATE TO anon USING (true) WITH CHECK (true);
CREATE POLICY "memorization_tags: anon delete"
  ON public.memorization_tags FOR DELETE TO anon USING (true);

CREATE POLICY "memorization_card_tags: anon select"
  ON public.memorization_card_tags FOR SELECT TO anon USING (true);
CREATE POLICY "memorization_card_tags: anon insert"
  ON public.memorization_card_tags FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY "memorization_card_tags: anon update"
  ON public.memorization_card_tags FOR UPDATE TO anon USING (true) WITH CHECK (true);
CREATE POLICY "memorization_card_tags: anon delete"
  ON public.memorization_card_tags FOR DELETE TO anon USING (true);
