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
  display_order INT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 既存の knowledge に subject_id が無い場合だけ追加（過去に別スキーマで作った場合用）
ALTER TABLE public.knowledge
  ADD COLUMN IF NOT EXISTS subject_id UUID REFERENCES public.subjects(id) ON DELETE SET NULL;

ALTER TABLE public.knowledge
  ADD COLUMN IF NOT EXISTS display_order INT;

-- subject を NULL 許可（既存DBで NOT NULL になっている場合の救済・インポートエラー解消）
ALTER TABLE public.knowledge
  ALTER COLUMN subject DROP NOT NULL;

-- 知識カード用タグ（RDB・中間テーブル）
CREATE TABLE IF NOT EXISTS public.knowledge_tags (
  id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL UNIQUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.knowledge_card_tags (
  knowledge_id UUID NOT NULL REFERENCES public.knowledge(id) ON DELETE CASCADE,
  tag_id       UUID NOT NULL REFERENCES public.knowledge_tags(id) ON DELETE CASCADE,
  PRIMARY KEY (knowledge_id, tag_id)
);
CREATE INDEX IF NOT EXISTS ix_knowledge_card_tags_tag_id
  ON public.knowledge_card_tags(tag_id);

-- 3) 暗記カード（例文など丸暗記用。知識カード＝解説メイン）
CREATE TABLE IF NOT EXISTS public.memorization_cards (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  subject_id    UUID        REFERENCES public.subjects(id) ON DELETE SET NULL,
  knowledge_id  UUID        REFERENCES public.knowledge(id) ON DELETE SET NULL,
  unit          TEXT,
  front_content TEXT        NOT NULL,
  back_content  TEXT,
  display_order INT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
DROP TRIGGER IF EXISTS trg_memorization_cards_updated_at ON public.memorization_cards;
CREATE TRIGGER trg_memorization_cards_updated_at
  BEFORE UPDATE ON public.memorization_cards
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- 暗記カード用タグ（RDB・中間テーブル）
CREATE TABLE IF NOT EXISTS public.memorization_tags (
  id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL UNIQUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.memorization_card_tags (
  memorization_card_id UUID NOT NULL REFERENCES public.memorization_cards(id) ON DELETE CASCADE,
  tag_id               UUID NOT NULL REFERENCES public.memorization_tags(id) ON DELETE CASCADE,
  PRIMARY KEY (memorization_card_id, tag_id)
);
CREATE INDEX IF NOT EXISTS ix_memorization_card_tags_tag_id
  ON public.memorization_card_tags(tag_id);

-- 4) 問題
CREATE TABLE IF NOT EXISTS public.questions (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  knowledge_id    UUID        REFERENCES public.knowledge(id) ON DELETE SET NULL,
  question_type   TEXT        NOT NULL DEFAULT 'text_input',
  question_text   TEXT        NOT NULL,
  correct_answer  TEXT        NOT NULL,
  explanation     TEXT,
  reference       TEXT,
  choices         JSONB,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 四択の選択肢（1問4行）
CREATE TABLE IF NOT EXISTS public.question_choices (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  question_id UUID        NOT NULL REFERENCES public.questions(id) ON DELETE CASCADE,
  position    INT         NOT NULL,
  choice_text TEXT        NOT NULL,
  is_correct  BOOLEAN     NOT NULL DEFAULT false,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (question_id, position)
);
CREATE INDEX IF NOT EXISTS ix_question_choices_question_id ON public.question_choices(question_id);

-- 問題と関連する知識（多対多）
CREATE TABLE IF NOT EXISTS public.question_knowledge (
  question_id  UUID    NOT NULL REFERENCES public.questions(id) ON DELETE CASCADE,
  knowledge_id UUID    NOT NULL REFERENCES public.knowledge(id) ON DELETE CASCADE,
  is_core      BOOLEAN NOT NULL DEFAULT false,
  PRIMARY KEY (question_id, knowledge_id)
);
CREATE INDEX IF NOT EXISTS ix_question_knowledge_knowledge_id ON public.question_knowledge(knowledge_id);
-- is_core: 既存DBへの追加（apply_schema.sql 再実行時用）
ALTER TABLE public.question_knowledge
  ADD COLUMN IF NOT EXISTS is_core BOOLEAN NOT NULL DEFAULT false;

-- 既存の knowledge_id を question_knowledge に移行（既存DB用）
INSERT INTO public.question_knowledge (question_id, knowledge_id)
SELECT id, knowledge_id FROM public.questions WHERE knowledge_id IS NOT NULL
ON CONFLICT (question_id, knowledge_id) DO NOTHING;
ALTER TABLE public.questions ALTER COLUMN knowledge_id DROP NOT NULL;

-- 5) updated_at 自動更新
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

-- 7) RLS（anon で全操作許可・開発用）
ALTER TABLE public.subjects ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.knowledge ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.questions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.memorization_cards ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.memorization_tags ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.memorization_card_tags ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.knowledge_tags ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.knowledge_card_tags ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.question_choices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.question_knowledge ENABLE ROW LEVEL SECURITY;

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

DROP POLICY IF EXISTS "knowledge_tags: anon select" ON public.knowledge_tags;
CREATE POLICY "knowledge_tags: anon select" ON public.knowledge_tags FOR SELECT TO anon USING (true);
DROP POLICY IF EXISTS "knowledge_tags: anon insert" ON public.knowledge_tags;
CREATE POLICY "knowledge_tags: anon insert" ON public.knowledge_tags FOR INSERT TO anon WITH CHECK (true);
DROP POLICY IF EXISTS "knowledge_tags: anon update" ON public.knowledge_tags;
CREATE POLICY "knowledge_tags: anon update" ON public.knowledge_tags FOR UPDATE TO anon USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "knowledge_tags: anon delete" ON public.knowledge_tags;
CREATE POLICY "knowledge_tags: anon delete" ON public.knowledge_tags FOR DELETE TO anon USING (true);

DROP POLICY IF EXISTS "knowledge_card_tags: anon select" ON public.knowledge_card_tags;
CREATE POLICY "knowledge_card_tags: anon select" ON public.knowledge_card_tags FOR SELECT TO anon USING (true);
DROP POLICY IF EXISTS "knowledge_card_tags: anon insert" ON public.knowledge_card_tags;
CREATE POLICY "knowledge_card_tags: anon insert" ON public.knowledge_card_tags FOR INSERT TO anon WITH CHECK (true);
DROP POLICY IF EXISTS "knowledge_card_tags: anon update" ON public.knowledge_card_tags;
CREATE POLICY "knowledge_card_tags: anon update" ON public.knowledge_card_tags FOR UPDATE TO anon USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "knowledge_card_tags: anon delete" ON public.knowledge_card_tags;
CREATE POLICY "knowledge_card_tags: anon delete" ON public.knowledge_card_tags FOR DELETE TO anon USING (true);

DROP POLICY IF EXISTS "questions: anon select" ON public.questions;
CREATE POLICY "questions: anon select" ON public.questions FOR SELECT TO anon USING (true);
DROP POLICY IF EXISTS "questions: anon insert" ON public.questions;
CREATE POLICY "questions: anon insert" ON public.questions FOR INSERT TO anon WITH CHECK (true);
DROP POLICY IF EXISTS "questions: anon update" ON public.questions;
CREATE POLICY "questions: anon update" ON public.questions FOR UPDATE TO anon USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "questions: anon delete" ON public.questions;
CREATE POLICY "questions: anon delete" ON public.questions FOR DELETE TO anon USING (true);

DROP POLICY IF EXISTS "memorization_cards: anon select" ON public.memorization_cards;
CREATE POLICY "memorization_cards: anon select" ON public.memorization_cards FOR SELECT TO anon USING (true);
DROP POLICY IF EXISTS "memorization_cards: anon insert" ON public.memorization_cards;
CREATE POLICY "memorization_cards: anon insert" ON public.memorization_cards FOR INSERT TO anon WITH CHECK (true);
DROP POLICY IF EXISTS "memorization_cards: anon update" ON public.memorization_cards;
CREATE POLICY "memorization_cards: anon update" ON public.memorization_cards FOR UPDATE TO anon USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "memorization_cards: anon delete" ON public.memorization_cards;
CREATE POLICY "memorization_cards: anon delete" ON public.memorization_cards FOR DELETE TO anon USING (true);

DROP POLICY IF EXISTS "memorization_tags: anon select" ON public.memorization_tags;
CREATE POLICY "memorization_tags: anon select" ON public.memorization_tags FOR SELECT TO anon USING (true);
DROP POLICY IF EXISTS "memorization_tags: anon insert" ON public.memorization_tags;
CREATE POLICY "memorization_tags: anon insert" ON public.memorization_tags FOR INSERT TO anon WITH CHECK (true);
DROP POLICY IF EXISTS "memorization_tags: anon update" ON public.memorization_tags;
CREATE POLICY "memorization_tags: anon update" ON public.memorization_tags FOR UPDATE TO anon USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "memorization_tags: anon delete" ON public.memorization_tags;
CREATE POLICY "memorization_tags: anon delete" ON public.memorization_tags FOR DELETE TO anon USING (true);

DROP POLICY IF EXISTS "memorization_card_tags: anon select" ON public.memorization_card_tags;
CREATE POLICY "memorization_card_tags: anon select" ON public.memorization_card_tags FOR SELECT TO anon USING (true);
DROP POLICY IF EXISTS "memorization_card_tags: anon insert" ON public.memorization_card_tags;
CREATE POLICY "memorization_card_tags: anon insert" ON public.memorization_card_tags FOR INSERT TO anon WITH CHECK (true);
DROP POLICY IF EXISTS "memorization_card_tags: anon update" ON public.memorization_card_tags;
CREATE POLICY "memorization_card_tags: anon update" ON public.memorization_card_tags FOR UPDATE TO anon USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "memorization_card_tags: anon delete" ON public.memorization_card_tags;
CREATE POLICY "memorization_card_tags: anon delete" ON public.memorization_card_tags FOR DELETE TO anon USING (true);

DROP POLICY IF EXISTS "question_choices: anon select" ON public.question_choices;
CREATE POLICY "question_choices: anon select" ON public.question_choices FOR SELECT TO anon USING (true);
DROP POLICY IF EXISTS "question_choices: anon insert" ON public.question_choices;
CREATE POLICY "question_choices: anon insert" ON public.question_choices FOR INSERT TO anon WITH CHECK (true);
DROP POLICY IF EXISTS "question_choices: anon update" ON public.question_choices;
CREATE POLICY "question_choices: anon update" ON public.question_choices FOR UPDATE TO anon USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "question_choices: anon delete" ON public.question_choices;
CREATE POLICY "question_choices: anon delete" ON public.question_choices FOR DELETE TO anon USING (true);

DROP POLICY IF EXISTS "question_knowledge: anon select" ON public.question_knowledge;
CREATE POLICY "question_knowledge: anon select" ON public.question_knowledge FOR SELECT TO anon USING (true);
DROP POLICY IF EXISTS "question_knowledge: anon insert" ON public.question_knowledge;
CREATE POLICY "question_knowledge: anon insert" ON public.question_knowledge FOR INSERT TO anon WITH CHECK (true);
DROP POLICY IF EXISTS "question_knowledge: anon update" ON public.question_knowledge;
CREATE POLICY "question_knowledge: anon update" ON public.question_knowledge FOR UPDATE TO anon USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "question_knowledge: anon delete" ON public.question_knowledge;
CREATE POLICY "question_knowledge: anon delete" ON public.question_knowledge FOR DELETE TO anon USING (true);

-- 8) 同期用 deleted_at（モバイル/デスクトップの SyncEngine 用。本番はマイグレーション 00014 を推奨）
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
UPDATE public.question_choices SET updated_at = created_at WHERE updated_at IS NULL;
ALTER TABLE public.question_choices ALTER COLUMN updated_at SET DEFAULT now();
DROP TRIGGER IF EXISTS trg_question_choices_updated_at ON public.question_choices;
CREATE TRIGGER trg_question_choices_updated_at
  BEFORE UPDATE ON public.question_choices
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- スキーマキャッシュを更新するため、Supabase は自動で行う。問題があればダッシュボードで「API を再読み込み」を実行。
