-- ============================================================
-- 暗記カード（例文など「丸暗記」用）
-- 知識カード = 解説メイン / 暗記カード = 暗記する本文（例文など）メイン
-- ============================================================

CREATE TABLE IF NOT EXISTS public.memorization_cards (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  subject_id    UUID        REFERENCES public.subjects(id) ON DELETE SET NULL,
  knowledge_id  UUID        REFERENCES public.knowledge(id) ON DELETE SET NULL,  -- 紐づく知識カード（任意）
  unit          TEXT,       -- セクション表示用（例: 仮定法）
  front_content TEXT        NOT NULL,   -- 表のコンテンツ
  back_content  TEXT,       -- 裏のコンテンツ
  display_order INT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_memorization_cards_updated_at
  BEFORE UPDATE ON public.memorization_cards
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

COMMENT ON TABLE public.memorization_cards IS '暗記カード。例文などをユーザーが丸暗記する用。知識カードは解説メイン。';
COMMENT ON COLUMN public.memorization_cards.knowledge_id IS '関連する知識カード（例: この例文が説明する文法）';
COMMENT ON COLUMN public.memorization_cards.front_content IS 'カード表のコンテンツ';
COMMENT ON COLUMN public.memorization_cards.back_content IS 'カード裏のコンテンツ';

-- RLS（知識カードと同じく anon で全操作許可）
ALTER TABLE public.memorization_cards ENABLE ROW LEVEL SECURITY;

CREATE POLICY "memorization_cards: anon select"
  ON public.memorization_cards FOR SELECT TO anon USING (true);

CREATE POLICY "memorization_cards: anon insert"
  ON public.memorization_cards FOR INSERT TO anon WITH CHECK (true);

CREATE POLICY "memorization_cards: anon update"
  ON public.memorization_cards FOR UPDATE TO anon USING (true) WITH CHECK (true);

CREATE POLICY "memorization_cards: anon delete"
  ON public.memorization_cards FOR DELETE TO anon USING (true);
