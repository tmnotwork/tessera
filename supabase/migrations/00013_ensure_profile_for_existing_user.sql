-- 既存ユーザーで profiles 行がない場合に自動作成する RPC（トリガー適用前の登録者用）
CREATE OR REPLACE FUNCTION public.ensure_my_profile()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO public.profiles (id, role, display_name)
  SELECT u.id,
         CASE WHEN u.email LIKE '%@tessera.local' THEN 'learner' ELSE 'teacher' END,
         u.email
  FROM auth.users u
  WHERE u.id = auth.uid()
  ON CONFLICT (id) DO NOTHING;
END;
$$;

GRANT EXECUTE ON FUNCTION public.ensure_my_profile() TO authenticated;

COMMENT ON FUNCTION public.ensure_my_profile() IS 'ログイン中ユーザーに profiles 行が無い場合に 1 回だけ作成する。メール登録=teacher、@tessera.local=learner。';
