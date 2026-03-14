-- ============================================================
-- knowledge の「くくり」用: subjects テーブル
-- 後から「英単語」「世界史」などを追加していく想定
-- ============================================================

-- 科目・くくりマスタ（英文法, 英単語, 世界史 など）
CREATE TABLE IF NOT EXISTS public.subjects (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL UNIQUE,
  display_order INT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 既存の knowledge テーブルに subject_id を追加（既にテーブルがある場合用）
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'knowledge' AND column_name = 'subject_id'
  ) THEN
    ALTER TABLE public.knowledge
      ADD COLUMN subject_id UUID REFERENCES public.subjects(id) ON DELETE SET NULL;
  END IF;
END $$;

-- 初回データ: 英文法 を追加（後から 英単語, 世界史 などを INSERT で追加可能）
INSERT INTO public.subjects (name, display_order)
VALUES ('英文法', 1)
ON CONFLICT (name) DO NOTHING;

-- 既存の knowledge で subject が 'english' / '英文法' の行を 英文法 に紐づけ（subject カラムがある場合のみ）
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'knowledge' AND column_name = 'subject'
  ) THEN
    UPDATE public.knowledge k
    SET subject_id = (SELECT id FROM public.subjects WHERE name = '英文法' LIMIT 1)
    WHERE k.subject_id IS NULL
      AND EXISTS (SELECT 1 FROM public.subjects WHERE name = '英文法')
      AND (k.subject = 'english' OR k.subject = '英文法' OR trim(coalesce(k.subject, '')) = '');
  END IF;
END $$;

COMMENT ON TABLE public.subjects IS '知識のくくり（英文法・英単語・世界史など）。後から科目を追加可能。';

-- 後からくくりを追加する例（Supabase SQL エディタで実行）:
-- INSERT INTO public.subjects (name, display_order) VALUES ('英単語', 2), ('世界史', 3) ON CONFLICT (name) DO NOTHING;
