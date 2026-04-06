-- 新規 questions の既定レビュー状態をブランクに。dev_completed は dev_review_status から常に整合させる。

ALTER TABLE public.questions
  ALTER COLUMN dev_review_status SET DEFAULT 'blank';

CREATE OR REPLACE FUNCTION public.sync_questions_dev_completed_from_review_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.dev_completed := (NEW.dev_review_status = 'completed');
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_questions_sync_dev_completed_from_review ON public.questions;
CREATE TRIGGER trg_questions_sync_dev_completed_from_review
  BEFORE INSERT OR UPDATE ON public.questions
  FOR EACH ROW
  EXECUTE FUNCTION public.sync_questions_dev_completed_from_review_status();

-- 既存行で不整合（completed 以外なのに dev_completed=true）を解消
UPDATE public.questions
SET dev_completed = (dev_review_status = 'completed')
WHERE dev_completed IS DISTINCT FROM (dev_review_status = 'completed');

COMMENT ON COLUMN public.questions.dev_review_status IS '執筆レビュー: blank=未着手, pending=要確認, completed=完了（dev_completed はトリガーで同期）';
