-- 暗記カードを content+hint から 表・裏（front_content / back_content）に移行
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'memorization_cards' AND column_name = 'content'
  ) THEN
    ALTER TABLE public.memorization_cards ADD COLUMN IF NOT EXISTS front_content TEXT;
    ALTER TABLE public.memorization_cards ADD COLUMN IF NOT EXISTS back_content TEXT;
    UPDATE public.memorization_cards SET front_content = content WHERE front_content IS NULL;
    UPDATE public.memorization_cards SET back_content = hint WHERE back_content IS NULL;
    ALTER TABLE public.memorization_cards ALTER COLUMN front_content SET NOT NULL;
    ALTER TABLE public.memorization_cards DROP COLUMN IF EXISTS content;
    ALTER TABLE public.memorization_cards DROP COLUMN IF EXISTS hint;
  END IF;
END $$;
