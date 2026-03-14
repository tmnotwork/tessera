-- 四択問題に「参考」カラムを追加（学習者画面で解説の後に表示）
ALTER TABLE public.questions
  ADD COLUMN IF NOT EXISTS reference TEXT;

COMMENT ON COLUMN public.questions.reference IS '参考情報。入力時は学習者画面で解説の後に別枠で表示する';
