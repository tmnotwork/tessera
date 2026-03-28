-- 英語例文: 出題時に条件を明示するヒント（例: 仮定法過去を使う）
ALTER TABLE public.english_examples
  ADD COLUMN IF NOT EXISTS prompt_supplement TEXT;

COMMENT ON COLUMN public.english_examples.prompt_supplement IS 'ヒント（時制・主語・文法指定など、和文だけで曖昧な条件を明示）';
