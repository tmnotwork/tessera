-- ============================================================
-- 英語例文の SM-2 学習状況管理
-- 学習者 × 例文ごとに進捗を保持する
-- ============================================================

CREATE TABLE IF NOT EXISTS public.english_example_learning_states (
  id               UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  learner_id       UUID          NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  example_id       UUID          NOT NULL REFERENCES public.english_examples(id) ON DELETE CASCADE,

  -- SM-2 フィールド
  repetitions      INT           NOT NULL DEFAULT 0,       -- 連続正解回数
  e_factor         DOUBLE PRECISION NOT NULL DEFAULT 2.5,  -- 熟練度係数（下限 1.3）
  interval_days    INT           NOT NULL DEFAULT 0,       -- 次回出題までの間隔（日）
  next_review_at   TIMESTAMPTZ   NOT NULL DEFAULT now(),   -- 次回出題日時

  -- 付加情報
  last_quality     INT,                                    -- 直前の評価 (0/1/3/4)
  reviewed_count   INT           NOT NULL DEFAULT 0,       -- 累計学習回数

  created_at       TIMESTAMPTZ   NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ   NOT NULL DEFAULT now(),

  UNIQUE (learner_id, example_id)
);

CREATE INDEX IF NOT EXISTS ix_eels_learner_next_review
  ON public.english_example_learning_states(learner_id, next_review_at ASC);

CREATE INDEX IF NOT EXISTS ix_eels_example_id
  ON public.english_example_learning_states(example_id);

CREATE OR REPLACE TRIGGER trg_eels_updated_at
  BEFORE UPDATE ON public.english_example_learning_states
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

COMMENT ON TABLE public.english_example_learning_states
  IS '英語例文の SM-2 学習状況。学習者×例文で一意。';

-- ------------------------------------------------------------
-- RLS
-- ------------------------------------------------------------
ALTER TABLE public.english_example_learning_states ENABLE ROW LEVEL SECURITY;

-- 学習者は自分のレコードのみ読み書き
CREATE POLICY "eels: learner own select"
  ON public.english_example_learning_states FOR SELECT TO authenticated
  USING (auth.uid() = learner_id);

CREATE POLICY "eels: learner own insert"
  ON public.english_example_learning_states FOR INSERT TO authenticated
  WITH CHECK (auth.uid() = learner_id);

CREATE POLICY "eels: learner own update"
  ON public.english_example_learning_states FOR UPDATE TO authenticated
  USING (auth.uid() = learner_id)
  WITH CHECK (auth.uid() = learner_id);

-- 教師は全学習者の状況を参照可
CREATE POLICY "eels: teacher read"
  ON public.english_example_learning_states FOR SELECT TO authenticated
  USING (public.get_my_role() = 'teacher');
