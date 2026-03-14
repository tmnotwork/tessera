-- knowledge.subject を NULL 許可にする（インポート時は subject_id のみで投入するため）
-- 既存DBで subject に NOT NULL が付いている場合の救済
ALTER TABLE public.knowledge
  ALTER COLUMN subject DROP NOT NULL;
