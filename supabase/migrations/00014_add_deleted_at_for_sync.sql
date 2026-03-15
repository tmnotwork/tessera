-- 双方向同期用: ソフトデリート検知のため deleted_at を追加
-- クライアントは削除時に UPDATE ... SET deleted_at = now() を実行。
-- 既存の set_updated_at トリガーにより updated_at も更新され、差分 Pull で取得される。

ALTER TABLE public.subjects
  ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

ALTER TABLE public.knowledge
  ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

ALTER TABLE public.memorization_cards
  ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

ALTER TABLE public.questions
  ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

ALTER TABLE public.question_choices
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ;
ALTER TABLE public.question_choices
  ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;
-- updated_at を既存行に設定（NULL のままなら差分 Pull で取りこぼすため）
UPDATE public.question_choices SET updated_at = created_at WHERE updated_at IS NULL;
ALTER TABLE public.question_choices ALTER COLUMN updated_at SET DEFAULT now();
DROP TRIGGER IF EXISTS trg_question_choices_updated_at ON public.question_choices;
CREATE TRIGGER trg_question_choices_updated_at
  BEFORE UPDATE ON public.question_choices
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
