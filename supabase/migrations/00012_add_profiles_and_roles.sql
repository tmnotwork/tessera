-- ============================================================
-- profiles テーブル・ロールベース認証・RLS 全更新
-- ============================================================

-- 1. profiles テーブル（教師・学習者共通）
CREATE TABLE IF NOT EXISTS public.profiles (
  id           UUID  PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  role         TEXT  NOT NULL DEFAULT 'teacher'
                     CHECK (role IN ('teacher', 'learner')),
  user_id      TEXT  UNIQUE,       -- 学習者のショートログインID (student01 等)。教師は NULL。
  display_name TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE OR REPLACE TRIGGER trg_profiles_updated_at
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

COMMENT ON TABLE  public.profiles         IS '教師・学習者共通プロフィール。role で区別する。';
COMMENT ON COLUMN public.profiles.user_id IS '学習者のショートログインID (student01 等)。教師は NULL。';

-- 2. 新規ユーザー登録時に role=teacher で自動作成するトリガー
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO public.profiles (id, role, display_name)
  VALUES (NEW.id, 'teacher', NEW.email)
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- 3. RLS ポリシー用ヘルパー（SECURITY DEFINER で profiles 自身の再帰を回避）
CREATE OR REPLACE FUNCTION public.get_my_role()
RETURNS TEXT LANGUAGE sql SECURITY DEFINER STABLE AS $$
  SELECT role FROM public.profiles WHERE id = auth.uid()
$$;

-- 4. profiles テーブルの RLS
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "profiles: own select"
  ON public.profiles FOR SELECT TO authenticated
  USING (auth.uid() = id);

CREATE POLICY "profiles: teacher read all"
  ON public.profiles FOR SELECT TO authenticated
  USING (public.get_my_role() = 'teacher');

CREATE POLICY "profiles: own update"
  ON public.profiles FOR UPDATE TO authenticated
  USING (auth.uid() = id);

CREATE POLICY "profiles: teacher insert learner"
  ON public.profiles FOR INSERT TO authenticated
  WITH CHECK (public.get_my_role() = 'teacher' AND role = 'learner');

-- ============================================================
-- 5. 既存の anon ポリシーを削除し、ロールベースに更新
--    対象テーブル:
--      subjects / knowledge / questions
--      memorization_cards / memorization_tags / memorization_card_tags
--      knowledge_tags / knowledge_card_tags
--      question_choices / question_knowledge
-- ============================================================

-- subjects
DROP POLICY IF EXISTS "subjects: anon select" ON public.subjects;
DROP POLICY IF EXISTS "subjects: anon insert" ON public.subjects;
DROP POLICY IF EXISTS "subjects: anon update" ON public.subjects;
DROP POLICY IF EXISTS "subjects: anon delete" ON public.subjects;

CREATE POLICY "subjects: teacher all"
  ON public.subjects FOR ALL TO authenticated
  USING      (public.get_my_role() = 'teacher')
  WITH CHECK (public.get_my_role() = 'teacher');

CREATE POLICY "subjects: learner read"
  ON public.subjects FOR SELECT TO authenticated USING (true);

-- knowledge
DROP POLICY IF EXISTS "knowledge: anon select" ON public.knowledge;
DROP POLICY IF EXISTS "knowledge: anon insert" ON public.knowledge;
DROP POLICY IF EXISTS "knowledge: anon update" ON public.knowledge;
DROP POLICY IF EXISTS "knowledge: anon delete" ON public.knowledge;

CREATE POLICY "knowledge: teacher all"
  ON public.knowledge FOR ALL TO authenticated
  USING      (public.get_my_role() = 'teacher')
  WITH CHECK (public.get_my_role() = 'teacher');

CREATE POLICY "knowledge: learner read"
  ON public.knowledge FOR SELECT TO authenticated USING (true);

-- questions
DROP POLICY IF EXISTS "questions: anon select" ON public.questions;
DROP POLICY IF EXISTS "questions: anon insert" ON public.questions;
DROP POLICY IF EXISTS "questions: anon update" ON public.questions;
DROP POLICY IF EXISTS "questions: anon delete" ON public.questions;

CREATE POLICY "questions: teacher all"
  ON public.questions FOR ALL TO authenticated
  USING      (public.get_my_role() = 'teacher')
  WITH CHECK (public.get_my_role() = 'teacher');

CREATE POLICY "questions: learner read"
  ON public.questions FOR SELECT TO authenticated USING (true);

-- memorization_cards
DROP POLICY IF EXISTS "memorization_cards: anon select" ON public.memorization_cards;
DROP POLICY IF EXISTS "memorization_cards: anon insert" ON public.memorization_cards;
DROP POLICY IF EXISTS "memorization_cards: anon update" ON public.memorization_cards;
DROP POLICY IF EXISTS "memorization_cards: anon delete" ON public.memorization_cards;

CREATE POLICY "memorization_cards: teacher all"
  ON public.memorization_cards FOR ALL TO authenticated
  USING      (public.get_my_role() = 'teacher')
  WITH CHECK (public.get_my_role() = 'teacher');

CREATE POLICY "memorization_cards: learner read"
  ON public.memorization_cards FOR SELECT TO authenticated USING (true);

-- memorization_tags
DROP POLICY IF EXISTS "memorization_tags: anon select" ON public.memorization_tags;
DROP POLICY IF EXISTS "memorization_tags: anon insert" ON public.memorization_tags;
DROP POLICY IF EXISTS "memorization_tags: anon update" ON public.memorization_tags;
DROP POLICY IF EXISTS "memorization_tags: anon delete" ON public.memorization_tags;

CREATE POLICY "memorization_tags: teacher all"
  ON public.memorization_tags FOR ALL TO authenticated
  USING      (public.get_my_role() = 'teacher')
  WITH CHECK (public.get_my_role() = 'teacher');

CREATE POLICY "memorization_tags: learner read"
  ON public.memorization_tags FOR SELECT TO authenticated USING (true);

-- memorization_card_tags
DROP POLICY IF EXISTS "memorization_card_tags: anon select" ON public.memorization_card_tags;
DROP POLICY IF EXISTS "memorization_card_tags: anon insert" ON public.memorization_card_tags;
DROP POLICY IF EXISTS "memorization_card_tags: anon update" ON public.memorization_card_tags;
DROP POLICY IF EXISTS "memorization_card_tags: anon delete" ON public.memorization_card_tags;

CREATE POLICY "memorization_card_tags: teacher all"
  ON public.memorization_card_tags FOR ALL TO authenticated
  USING      (public.get_my_role() = 'teacher')
  WITH CHECK (public.get_my_role() = 'teacher');

CREATE POLICY "memorization_card_tags: learner read"
  ON public.memorization_card_tags FOR SELECT TO authenticated USING (true);

-- knowledge_tags
DROP POLICY IF EXISTS "knowledge_tags: anon select" ON public.knowledge_tags;
DROP POLICY IF EXISTS "knowledge_tags: anon insert" ON public.knowledge_tags;
DROP POLICY IF EXISTS "knowledge_tags: anon update" ON public.knowledge_tags;
DROP POLICY IF EXISTS "knowledge_tags: anon delete" ON public.knowledge_tags;

CREATE POLICY "knowledge_tags: teacher all"
  ON public.knowledge_tags FOR ALL TO authenticated
  USING      (public.get_my_role() = 'teacher')
  WITH CHECK (public.get_my_role() = 'teacher');

CREATE POLICY "knowledge_tags: learner read"
  ON public.knowledge_tags FOR SELECT TO authenticated USING (true);

-- knowledge_card_tags
DROP POLICY IF EXISTS "knowledge_card_tags: anon select" ON public.knowledge_card_tags;
DROP POLICY IF EXISTS "knowledge_card_tags: anon insert" ON public.knowledge_card_tags;
DROP POLICY IF EXISTS "knowledge_card_tags: anon update" ON public.knowledge_card_tags;
DROP POLICY IF EXISTS "knowledge_card_tags: anon delete" ON public.knowledge_card_tags;

CREATE POLICY "knowledge_card_tags: teacher all"
  ON public.knowledge_card_tags FOR ALL TO authenticated
  USING      (public.get_my_role() = 'teacher')
  WITH CHECK (public.get_my_role() = 'teacher');

CREATE POLICY "knowledge_card_tags: learner read"
  ON public.knowledge_card_tags FOR SELECT TO authenticated USING (true);

-- question_choices
DROP POLICY IF EXISTS "question_choices: anon select" ON public.question_choices;
DROP POLICY IF EXISTS "question_choices: anon insert" ON public.question_choices;
DROP POLICY IF EXISTS "question_choices: anon update" ON public.question_choices;
DROP POLICY IF EXISTS "question_choices: anon delete" ON public.question_choices;

CREATE POLICY "question_choices: teacher all"
  ON public.question_choices FOR ALL TO authenticated
  USING      (public.get_my_role() = 'teacher')
  WITH CHECK (public.get_my_role() = 'teacher');

CREATE POLICY "question_choices: learner read"
  ON public.question_choices FOR SELECT TO authenticated USING (true);

-- question_knowledge
DROP POLICY IF EXISTS "question_knowledge: anon select" ON public.question_knowledge;
DROP POLICY IF EXISTS "question_knowledge: anon insert" ON public.question_knowledge;
DROP POLICY IF EXISTS "question_knowledge: anon update" ON public.question_knowledge;
DROP POLICY IF EXISTS "question_knowledge: anon delete" ON public.question_knowledge;

CREATE POLICY "question_knowledge: teacher all"
  ON public.question_knowledge FOR ALL TO authenticated
  USING      (public.get_my_role() = 'teacher')
  WITH CHECK (public.get_my_role() = 'teacher');

CREATE POLICY "question_knowledge: learner read"
  ON public.question_knowledge FOR SELECT TO authenticated USING (true);
