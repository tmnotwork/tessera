-- 1 知識カードに複数の英語例文を紐づけられるようにする
ALTER TABLE public.english_examples
  DROP CONSTRAINT IF EXISTS english_examples_knowledge_unique;

COMMENT ON TABLE public.english_examples IS '英語例文DB。表=日本語、裏=英語、解説・補足を保持。knowledge とは多対1。';
