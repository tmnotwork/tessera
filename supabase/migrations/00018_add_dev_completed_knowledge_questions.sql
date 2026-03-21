-- AI 生成カードの開発者確認（「完成」）フラグ
ALTER TABLE public.knowledge
  ADD COLUMN IF NOT EXISTS dev_completed BOOLEAN NOT NULL DEFAULT false;

ALTER TABLE public.questions
  ADD COLUMN IF NOT EXISTS dev_completed BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN public.knowledge.dev_completed IS '開発者が内容確認済み（AI 生成カードのレビュー用）';
COMMENT ON COLUMN public.questions.dev_completed IS '開発者が内容確認済み（AI 生成カードのレビュー用）';
