-- ============================================================
-- 英語例文「英作文」モード専用の学習記録
-- （読み上げ画面の SM-2 / last_quality とは別集計）
-- ============================================================

CREATE TABLE IF NOT EXISTS public.english_example_composition_states (
  id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  learner_id             UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  example_id             UUID NOT NULL REFERENCES public.english_examples(id) ON DELETE CASCADE,

  last_answer_correct    BOOLEAN,
  last_self_remembered   BOOLEAN,

  attempts               INT NOT NULL DEFAULT 0,
  correct_count          INT NOT NULL DEFAULT 0,
  remembered_count       INT NOT NULL DEFAULT 0,
  forgot_count           INT NOT NULL DEFAULT 0,

  created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at             TIMESTAMPTZ NOT NULL DEFAULT now(),

  UNIQUE (learner_id, example_id)
);

CREATE INDEX IF NOT EXISTS ix_eecs_learner_example
  ON public.english_example_composition_states(learner_id, example_id);

COMMENT ON TABLE public.english_example_composition_states IS '英作文モードの正誤・覚えた/覚えていない（読み上げの learning_states と別集計）';

DROP TRIGGER IF EXISTS trg_eecs_updated_at ON public.english_example_composition_states;
CREATE TRIGGER trg_eecs_updated_at
  BEFORE UPDATE ON public.english_example_composition_states
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.english_example_composition_states ENABLE ROW LEVEL SECURITY;

CREATE POLICY "eecs: learner own select"
  ON public.english_example_composition_states FOR SELECT TO authenticated
  USING (auth.uid() = learner_id);

CREATE POLICY "eecs: learner own insert"
  ON public.english_example_composition_states FOR INSERT TO authenticated
  WITH CHECK (auth.uid() = learner_id);

CREATE POLICY "eecs: learner own update"
  ON public.english_example_composition_states FOR UPDATE TO authenticated
  USING (auth.uid() = learner_id)
  WITH CHECK (auth.uid() = learner_id);

CREATE POLICY "eecs: teacher read"
  ON public.english_example_composition_states FOR SELECT TO authenticated
  USING (public.get_my_role() = 'teacher');
