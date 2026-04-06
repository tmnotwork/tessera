-- 四択問題のレビュー状態を3値で保持（ブランク／要確認／完成）。dev_completed は後方互換のため「完成」と同期。
ALTER TABLE public.questions
  ADD COLUMN IF NOT EXISTS dev_review_status TEXT NOT NULL DEFAULT 'pending';

UPDATE public.questions
SET dev_review_status = CASE
  WHEN dev_completed THEN 'completed'
  ELSE 'pending'
END
WHERE dev_review_status = 'pending';

ALTER TABLE public.questions DROP CONSTRAINT IF EXISTS questions_dev_review_status_check;
ALTER TABLE public.questions
  ADD CONSTRAINT questions_dev_review_status_check
  CHECK (dev_review_status IN ('blank', 'pending', 'completed'));

COMMENT ON COLUMN public.questions.dev_review_status IS '執筆レビュー: blank=未着手, pending=要確認, completed=完成（dev_completed と整合）';
