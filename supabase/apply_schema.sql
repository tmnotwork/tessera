-- ============================================================
-- データベースを一括で整えるスクリプト（1回だけ実行）
-- Supabase ダッシュボード → SQL エディタ → 新規クエリに貼り付けて実行
-- 既存テーブルがある場合も安全（IF NOT EXISTS / ADD COLUMN IF NOT EXISTS）
-- ============================================================

-- 1) 科目マスタ
CREATE TABLE IF NOT EXISTS public.subjects (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name          TEXT        NOT NULL UNIQUE,
  display_order INT         NOT NULL DEFAULT 0,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 2) 知識本体（subject_id を最初から含む）
CREATE TABLE IF NOT EXISTS public.knowledge (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  subject_id    UUID        REFERENCES public.subjects(id) ON DELETE SET NULL,
  subject       TEXT,
  unit          TEXT,
  content       TEXT        NOT NULL,
  description   TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 既存の knowledge に subject_id が無い場合だけ追加（過去に別スキーマで作った場合用）
ALTER TABLE public.knowledge
  ADD COLUMN IF NOT EXISTS subject_id UUID REFERENCES public.subjects(id) ON DELETE SET NULL;

-- subject を NULL 許可（既存DBで NOT NULL になっている場合の救済・インポートエラー解消）
ALTER TABLE public.knowledge
  ALTER COLUMN subject DROP NOT NULL;

-- 3) 問題
CREATE TABLE IF NOT EXISTS public.questions (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  knowledge_id    UUID        NOT NULL REFERENCES public.knowledge(id) ON DELETE CASCADE,
  question_type   TEXT        NOT NULL DEFAULT 'text_input',
  question_text   TEXT        NOT NULL,
  correct_answer  TEXT        NOT NULL,
  explanation     TEXT,
  choices         JSONB,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 4) updated_at 自動更新
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_subjects_updated_at ON public.subjects;
CREATE TRIGGER trg_subjects_updated_at
  BEFORE UPDATE ON public.subjects
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS trg_knowledge_updated_at ON public.knowledge;
CREATE TRIGGER trg_knowledge_updated_at
  BEFORE UPDATE ON public.knowledge
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS trg_questions_updated_at ON public.questions;
CREATE TRIGGER trg_questions_updated_at
  BEFORE UPDATE ON public.questions
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- 5) 初回データ: 英文法
INSERT INTO public.subjects (name, display_order)
VALUES ('英文法', 1)
ON CONFLICT (name) DO NOTHING;

-- 6) RLS（anon で全操作許可・開発用）
ALTER TABLE public.subjects ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.knowledge ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.questions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "subjects: anon select" ON public.subjects;
CREATE POLICY "subjects: anon select" ON public.subjects FOR SELECT TO anon USING (true);
DROP POLICY IF EXISTS "subjects: anon insert" ON public.subjects;
CREATE POLICY "subjects: anon insert" ON public.subjects FOR INSERT TO anon WITH CHECK (true);
DROP POLICY IF EXISTS "subjects: anon update" ON public.subjects;
CREATE POLICY "subjects: anon update" ON public.subjects FOR UPDATE TO anon USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "subjects: anon delete" ON public.subjects;
CREATE POLICY "subjects: anon delete" ON public.subjects FOR DELETE TO anon USING (true);

DROP POLICY IF EXISTS "knowledge: anon select" ON public.knowledge;
CREATE POLICY "knowledge: anon select" ON public.knowledge FOR SELECT TO anon USING (true);
DROP POLICY IF EXISTS "knowledge: anon insert" ON public.knowledge;
CREATE POLICY "knowledge: anon insert" ON public.knowledge FOR INSERT TO anon WITH CHECK (true);
DROP POLICY IF EXISTS "knowledge: anon update" ON public.knowledge;
CREATE POLICY "knowledge: anon update" ON public.knowledge FOR UPDATE TO anon USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "knowledge: anon delete" ON public.knowledge;
CREATE POLICY "knowledge: anon delete" ON public.knowledge FOR DELETE TO anon USING (true);

DROP POLICY IF EXISTS "questions: anon select" ON public.questions;
CREATE POLICY "questions: anon select" ON public.questions FOR SELECT TO anon USING (true);
DROP POLICY IF EXISTS "questions: anon insert" ON public.questions;
CREATE POLICY "questions: anon insert" ON public.questions FOR INSERT TO anon WITH CHECK (true);
DROP POLICY IF EXISTS "questions: anon update" ON public.questions;
CREATE POLICY "questions: anon update" ON public.questions FOR UPDATE TO anon USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "questions: anon delete" ON public.questions;
CREATE POLICY "questions: anon delete" ON public.questions FOR DELETE TO anon USING (true);

-- スキーマキャッシュを更新するため、Supabase は自動で行う。問題があればダッシュボードで「API を再読み込み」を実行。
