-- SyncEngine が upsert するため UPDATE が必要（00023 適用済み環境向け）
DROP POLICY IF EXISTS "study_sessions: learner own update" ON public.study_sessions;
CREATE POLICY "study_sessions: learner own update"
  ON public.study_sessions FOR UPDATE TO authenticated
  USING (auth.uid() = learner_id)
  WITH CHECK (auth.uid() = learner_id);
