-- ============================================================
-- ベーステーブル: knowledge / questions
-- subjects は 00001 で作成される前提だが、ここでも安全に定義
-- ============================================================

-- subjects（科目マスタ）
CREATE TABLE IF NOT EXISTS public.subjects (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name          TEXT        NOT NULL UNIQUE,
  display_order INT         NOT NULL DEFAULT 0,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 知識本体
CREATE TABLE IF NOT EXISTS public.knowledge (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  subject_id    UUID        REFERENCES public.subjects(id) ON DELETE SET NULL,
  subject       TEXT,                        -- レガシー互換用（同期コードで参照）
  unit          TEXT,
  content       TEXT        NOT NULL,
  description   TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 問題（knowledge に 1:N で紐づく）
CREATE TABLE IF NOT EXISTS public.questions (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  knowledge_id    UUID        NOT NULL REFERENCES public.knowledge(id) ON DELETE CASCADE,
  question_type   TEXT        NOT NULL DEFAULT 'text_input',  -- 'text_input' | 'multiple_choice' | 'flashcard'
  question_text   TEXT        NOT NULL,
  correct_answer  TEXT        NOT NULL,
  explanation     TEXT,
  choices         JSONB,      -- 四択用: ["選択肢A","選択肢B","選択肢C","選択肢D"]
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- updated_at 自動更新トリガー
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER trg_subjects_updated_at
  BEFORE UPDATE ON public.subjects
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE OR REPLACE TRIGGER trg_knowledge_updated_at
  BEFORE UPDATE ON public.knowledge
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE OR REPLACE TRIGGER trg_questions_updated_at
  BEFORE UPDATE ON public.questions
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

COMMENT ON TABLE public.knowledge  IS '知識の最小単位（単語・出来事など）';
COMMENT ON TABLE public.questions  IS 'knowledge に紐づく出題データ';
