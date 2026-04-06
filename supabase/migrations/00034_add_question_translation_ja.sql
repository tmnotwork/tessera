-- 四択問題の問題文和訳（日本語）を保持するカラムを追加
ALTER TABLE public.questions
  ADD COLUMN IF NOT EXISTS question_translation_ja TEXT;

COMMENT ON COLUMN public.questions.question_translation_ja IS
  '問題文の和訳（日本語）。学習者の正解表示画面などで表示する';
