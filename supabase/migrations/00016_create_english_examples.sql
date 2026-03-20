-- ============================================================
-- 英語例文DB（日本語⇔英語 + 解説 + 補足）
-- 例文は knowledge と 1:1 で紐づける
-- ============================================================

CREATE TABLE IF NOT EXISTS public.english_examples (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  knowledge_id  UUID        NOT NULL REFERENCES public.knowledge(id) ON DELETE CASCADE,
  front_ja      TEXT        NOT NULL, -- 表（日本語）
  back_en       TEXT        NOT NULL, -- 裏（英語）
  explanation   TEXT,                 -- 解説
  supplement    TEXT,                 -- 補足
  display_order INT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT english_examples_knowledge_unique UNIQUE (knowledge_id)
);

CREATE INDEX IF NOT EXISTS ix_english_examples_display_order
  ON public.english_examples(display_order);

CREATE OR REPLACE TRIGGER trg_english_examples_updated_at
  BEFORE UPDATE ON public.english_examples
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

COMMENT ON TABLE public.english_examples IS '英語例文DB。表=日本語、裏=英語、解説・補足を保持。knowledge と 1:1。';
COMMENT ON COLUMN public.english_examples.knowledge_id IS '対応する知識カードID（1対1）';
COMMENT ON COLUMN public.english_examples.front_ja IS '表（日本語）';
COMMENT ON COLUMN public.english_examples.back_en IS '裏（英語）';
COMMENT ON COLUMN public.english_examples.explanation IS '解説';
COMMENT ON COLUMN public.english_examples.supplement IS '補足';

ALTER TABLE public.english_examples ENABLE ROW LEVEL SECURITY;

-- 教師は全操作可
CREATE POLICY "english_examples: teacher all"
  ON public.english_examples FOR ALL TO authenticated
  USING      (public.get_my_role() = 'teacher')
  WITH CHECK (public.get_my_role() = 'teacher');

-- 学習者は参照のみ可
CREATE POLICY "english_examples: learner read"
  ON public.english_examples FOR SELECT TO authenticated
  USING (true);
