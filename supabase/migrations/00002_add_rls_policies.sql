-- ============================================================
-- RLS (Row Level Security) ポリシー設定
-- 現状: 認証なし開発フェーズのため anon に全操作を許可
-- 本番化時に teacher ロール限定などへ段階的に絞る
-- ============================================================

-- subjects
ALTER TABLE public.subjects ENABLE ROW LEVEL SECURITY;

CREATE POLICY "subjects: anon select"
  ON public.subjects FOR SELECT TO anon USING (true);

CREATE POLICY "subjects: anon insert"
  ON public.subjects FOR INSERT TO anon WITH CHECK (true);

CREATE POLICY "subjects: anon update"
  ON public.subjects FOR UPDATE TO anon USING (true) WITH CHECK (true);

CREATE POLICY "subjects: anon delete"
  ON public.subjects FOR DELETE TO anon USING (true);

-- knowledge
ALTER TABLE public.knowledge ENABLE ROW LEVEL SECURITY;

CREATE POLICY "knowledge: anon select"
  ON public.knowledge FOR SELECT TO anon USING (true);

CREATE POLICY "knowledge: anon insert"
  ON public.knowledge FOR INSERT TO anon WITH CHECK (true);

CREATE POLICY "knowledge: anon update"
  ON public.knowledge FOR UPDATE TO anon USING (true) WITH CHECK (true);

CREATE POLICY "knowledge: anon delete"
  ON public.knowledge FOR DELETE TO anon USING (true);

-- questions
ALTER TABLE public.questions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "questions: anon select"
  ON public.questions FOR SELECT TO anon USING (true);

CREATE POLICY "questions: anon insert"
  ON public.questions FOR INSERT TO anon WITH CHECK (true);

CREATE POLICY "questions: anon update"
  ON public.questions FOR UPDATE TO anon USING (true) WITH CHECK (true);

CREATE POLICY "questions: anon delete"
  ON public.questions FOR DELETE TO anon USING (true);
