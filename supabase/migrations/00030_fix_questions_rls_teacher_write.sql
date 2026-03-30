-- 本番で 00012 が未適用のとき、authenticated が questions 等で SELECT のみになり教師の UPDATE が 0 件になる不整合を修復する。
-- get_my_role() は 00012 / 00013 で既に存在する前提。

-- questions
DROP POLICY IF EXISTS "questions: authenticated select" ON public.questions;
DROP POLICY IF EXISTS "questions: anon select" ON public.questions;
DROP POLICY IF EXISTS "questions: anon insert" ON public.questions;
DROP POLICY IF EXISTS "questions: anon update" ON public.questions;
DROP POLICY IF EXISTS "questions: anon delete" ON public.questions;
DROP POLICY IF EXISTS "questions: teacher all" ON public.questions;
DROP POLICY IF EXISTS "questions: learner read" ON public.questions;

CREATE POLICY "questions: teacher all"
  ON public.questions FOR ALL TO authenticated
  USING      (public.get_my_role() = 'teacher')
  WITH CHECK (public.get_my_role() = 'teacher');

CREATE POLICY "questions: learner read"
  ON public.questions FOR SELECT TO authenticated USING (true);

-- question_choices
DROP POLICY IF EXISTS "question_choices: authenticated select" ON public.question_choices;
DROP POLICY IF EXISTS "question_choices: anon select" ON public.question_choices;
DROP POLICY IF EXISTS "question_choices: anon insert" ON public.question_choices;
DROP POLICY IF EXISTS "question_choices: anon update" ON public.question_choices;
DROP POLICY IF EXISTS "question_choices: anon delete" ON public.question_choices;
DROP POLICY IF EXISTS "question_choices: teacher all" ON public.question_choices;
DROP POLICY IF EXISTS "question_choices: learner read" ON public.question_choices;

CREATE POLICY "question_choices: teacher all"
  ON public.question_choices FOR ALL TO authenticated
  USING      (public.get_my_role() = 'teacher')
  WITH CHECK (public.get_my_role() = 'teacher');

CREATE POLICY "question_choices: learner read"
  ON public.question_choices FOR SELECT TO authenticated USING (true);

-- question_knowledge
DROP POLICY IF EXISTS "question_knowledge: authenticated select" ON public.question_knowledge;
DROP POLICY IF EXISTS "question_knowledge: anon select" ON public.question_knowledge;
DROP POLICY IF EXISTS "question_knowledge: anon insert" ON public.question_knowledge;
DROP POLICY IF EXISTS "question_knowledge: anon update" ON public.question_knowledge;
DROP POLICY IF EXISTS "question_knowledge: anon delete" ON public.question_knowledge;
DROP POLICY IF EXISTS "question_knowledge: teacher all" ON public.question_knowledge;
DROP POLICY IF EXISTS "question_knowledge: learner read" ON public.question_knowledge;

CREATE POLICY "question_knowledge: teacher all"
  ON public.question_knowledge FOR ALL TO authenticated
  USING      (public.get_my_role() = 'teacher')
  WITH CHECK (public.get_my_role() = 'teacher');

CREATE POLICY "question_knowledge: learner read"
  ON public.question_knowledge FOR SELECT TO authenticated USING (true);
