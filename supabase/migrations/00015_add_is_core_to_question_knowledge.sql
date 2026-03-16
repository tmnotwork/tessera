-- ============================================================
-- question_knowledge に is_core フラグを追加
-- コア問題：知識カードの習得確認に必須な問題
-- 非コア問題：追加演習用（ユーザーが深堀りしたいときだけ解く）
-- ============================================================

ALTER TABLE public.question_knowledge
  ADD COLUMN IF NOT EXISTS is_core BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN public.question_knowledge.is_core IS 'コア問題フラグ。true=知識習得の必須問題、false=追加演習用問題';
