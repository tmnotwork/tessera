-- ============================================================
-- 四択問題DB：選択肢テーブル + 問題⇔知識の多対多
-- 問題(questions) / 四択の選択肢(question_choices) / 関連する知識(question_knowledge)
-- ============================================================

-- 四択の選択肢（1問あたり4行）
CREATE TABLE IF NOT EXISTS public.question_choices (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  question_id UUID        NOT NULL REFERENCES public.questions(id) ON DELETE CASCADE,
  position    INT         NOT NULL,   -- 1〜4
  choice_text TEXT        NOT NULL,
  is_correct  BOOLEAN     NOT NULL DEFAULT false,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (question_id, position)
);

CREATE INDEX IF NOT EXISTS ix_question_choices_question_id
  ON public.question_choices(question_id);

COMMENT ON TABLE public.question_choices IS '四択問題の選択肢（1問4行）';
COMMENT ON COLUMN public.question_choices.position IS '選択肢の並び順（1〜4）';

-- 問題と知識の多対多（関連する知識）
CREATE TABLE IF NOT EXISTS public.question_knowledge (
  question_id UUID NOT NULL REFERENCES public.questions(id) ON DELETE CASCADE,
  knowledge_id UUID NOT NULL REFERENCES public.knowledge(id) ON DELETE CASCADE,
  PRIMARY KEY (question_id, knowledge_id)
);

CREATE INDEX IF NOT EXISTS ix_question_knowledge_knowledge_id
  ON public.question_knowledge(knowledge_id);

COMMENT ON TABLE public.question_knowledge IS '問題と関連する知識カードの多対多';

-- 既存の questions.knowledge_id を question_knowledge に移行
INSERT INTO public.question_knowledge (question_id, knowledge_id)
SELECT id, knowledge_id FROM public.questions WHERE knowledge_id IS NOT NULL
ON CONFLICT (question_id, knowledge_id) DO NOTHING;

-- questions.knowledge_id を NULL 許可に（関連は question_knowledge で持つ想定）
ALTER TABLE public.questions
  ALTER COLUMN knowledge_id DROP NOT NULL;

-- RLS
ALTER TABLE public.question_choices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.question_knowledge ENABLE ROW LEVEL SECURITY;

CREATE POLICY "question_choices: anon select"
  ON public.question_choices FOR SELECT TO anon USING (true);
CREATE POLICY "question_choices: anon insert"
  ON public.question_choices FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY "question_choices: anon update"
  ON public.question_choices FOR UPDATE TO anon USING (true) WITH CHECK (true);
CREATE POLICY "question_choices: anon delete"
  ON public.question_choices FOR DELETE TO anon USING (true);

CREATE POLICY "question_knowledge: anon select"
  ON public.question_knowledge FOR SELECT TO anon USING (true);
CREATE POLICY "question_knowledge: anon insert"
  ON public.question_knowledge FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY "question_knowledge: anon update"
  ON public.question_knowledge FOR UPDATE TO anon USING (true) WITH CHECK (true);
CREATE POLICY "question_knowledge: anon delete"
  ON public.question_knowledge FOR DELETE TO anon USING (true);
