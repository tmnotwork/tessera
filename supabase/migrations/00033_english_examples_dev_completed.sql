-- 英語例文のレビュー状態（四択・知識カードの dev_completed と同趣旨）
ALTER TABLE public.english_examples
  ADD COLUMN IF NOT EXISTS dev_completed BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN public.english_examples.dev_completed IS '開発者が内容確認済み（要確認=false / 完成=true）';
