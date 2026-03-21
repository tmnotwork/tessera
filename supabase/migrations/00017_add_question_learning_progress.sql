-- ============================================================
-- 四択問題の忘却曲線ベース進捗管理
-- - question_answer_logs: 解答イベント履歴
-- - question_learning_states: 学習者×問題の現在状態
-- ============================================================

CREATE TABLE IF NOT EXISTS public.question_answer_logs (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  learner_id           UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  question_id          UUID NOT NULL REFERENCES public.questions(id) ON DELETE CASCADE,
  selected_choice_text TEXT,
  selected_index       INT,
  is_correct           BOOLEAN NOT NULL,
  answered_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_question_answer_logs_learner_id_answered_at
  ON public.question_answer_logs(learner_id, answered_at DESC);

CREATE INDEX IF NOT EXISTS ix_question_answer_logs_question_id
  ON public.question_answer_logs(question_id);

COMMENT ON TABLE public.question_answer_logs IS '四択解答の履歴ログ（監査・分析用）';

CREATE OR REPLACE TRIGGER trg_question_answer_logs_updated_at
  BEFORE UPDATE ON public.question_answer_logs
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE IF NOT EXISTS public.question_learning_states (
  id                        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  learner_id                UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  question_id               UUID NOT NULL REFERENCES public.questions(id) ON DELETE CASCADE,
  stability                 DOUBLE PRECISION NOT NULL DEFAULT 1.0,
  difficulty                DOUBLE PRECISION NOT NULL DEFAULT 0.5,
  retrievability            DOUBLE PRECISION NOT NULL DEFAULT 0.5,
  success_streak            INT NOT NULL DEFAULT 0,
  lapse_count               INT NOT NULL DEFAULT 0,
  reviewed_count            INT NOT NULL DEFAULT 0,
  last_is_correct           BOOLEAN,
  last_selected_choice_text TEXT,
  last_selected_index       INT,
  last_review_at            TIMESTAMPTZ,
  next_review_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (learner_id, question_id)
);

CREATE INDEX IF NOT EXISTS ix_question_learning_states_learner_id_next_review_at
  ON public.question_learning_states(learner_id, next_review_at ASC);

CREATE INDEX IF NOT EXISTS ix_question_learning_states_question_id
  ON public.question_learning_states(question_id);

COMMENT ON TABLE public.question_learning_states IS '学習者×問題の忘却曲線用状態（次回復習日を管理）';

CREATE OR REPLACE TRIGGER trg_question_learning_states_updated_at
  BEFORE UPDATE ON public.question_learning_states
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ------------------------------------------------------------
-- RLS
-- ------------------------------------------------------------
ALTER TABLE public.question_answer_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.question_learning_states ENABLE ROW LEVEL SECURITY;

CREATE POLICY "question_answer_logs: learner own read"
  ON public.question_answer_logs FOR SELECT TO authenticated
  USING (auth.uid() = learner_id);

CREATE POLICY "question_answer_logs: learner own insert"
  ON public.question_answer_logs FOR INSERT TO authenticated
  WITH CHECK (auth.uid() = learner_id);

CREATE POLICY "question_answer_logs: teacher read"
  ON public.question_answer_logs FOR SELECT TO authenticated
  USING (public.get_my_role() = 'teacher');

CREATE POLICY "question_learning_states: learner own read"
  ON public.question_learning_states FOR SELECT TO authenticated
  USING (auth.uid() = learner_id);

CREATE POLICY "question_learning_states: learner own insert"
  ON public.question_learning_states FOR INSERT TO authenticated
  WITH CHECK (auth.uid() = learner_id);

CREATE POLICY "question_learning_states: learner own update"
  ON public.question_learning_states FOR UPDATE TO authenticated
  USING (auth.uid() = learner_id)
  WITH CHECK (auth.uid() = learner_id);

CREATE POLICY "question_learning_states: teacher read"
  ON public.question_learning_states FOR SELECT TO authenticated
  USING (public.get_my_role() = 'teacher');
