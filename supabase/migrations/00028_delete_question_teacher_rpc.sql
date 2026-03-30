-- 教師の四択・問題削除を確実に行う（PostgREST 経由の DELETE が RLS で 0 行になるケースの救済）
-- SECURITY DEFINER で RLS をバイパスするが、関数内で profiles.role = 'teacher' を必須とする。

CREATE OR REPLACE FUNCTION public.delete_question_if_teacher(p_question_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role text;
  v_n int;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION '認証されていません';
  END IF;

  SELECT role INTO v_role FROM public.profiles WHERE id = auth.uid();
  IF v_role IS NULL OR v_role <> 'teacher' THEN
    RAISE EXCEPTION '教師のみ問題を削除できます';
  END IF;

  DELETE FROM public.questions WHERE id = p_question_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n > 0;
END;
$$;

COMMENT ON FUNCTION public.delete_question_if_teacher(uuid) IS
  '認証ユーザが profiles.role=teacher のときのみ questions を削除。子テーブルは FK の ON DELETE CASCADE に従う。';

REVOKE ALL ON FUNCTION public.delete_question_if_teacher(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_question_if_teacher(uuid) TO authenticated;
