-- ============================================================
-- 勉強時間セッション（学習者端末からの Push 用）
-- ============================================================

CREATE TABLE IF NOT EXISTS public.study_sessions (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  learner_id    UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  session_type  TEXT NOT NULL,
  content_id    TEXT,
  content_title TEXT,
  unit          TEXT,
  subject_id    TEXT,
  subject_name  TEXT,
  tts_sec       INT NOT NULL DEFAULT 0,
  started_at    TIMESTAMPTZ NOT NULL,
  ended_at      TIMESTAMPTZ NOT NULL,
  duration_sec  INT NOT NULL DEFAULT 0,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_study_sessions_learner_started
  ON public.study_sessions(learner_id, started_at DESC);

COMMENT ON TABLE public.study_sessions IS '学習画面滞在時間のセッションログ（端末から同期）';

ALTER TABLE public.study_sessions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "study_sessions: learner own read"
  ON public.study_sessions FOR SELECT TO authenticated
  USING (auth.uid() = learner_id);

CREATE POLICY "study_sessions: learner own insert"
  ON public.study_sessions FOR INSERT TO authenticated
  WITH CHECK (auth.uid() = learner_id);

CREATE POLICY "study_sessions: learner own update"
  ON public.study_sessions FOR UPDATE TO authenticated
  USING (auth.uid() = learner_id)
  WITH CHECK (auth.uid() = learner_id);

CREATE POLICY "study_sessions: teacher read"
  ON public.study_sessions FOR SELECT TO authenticated
  USING (public.get_my_role() = 'teacher');
