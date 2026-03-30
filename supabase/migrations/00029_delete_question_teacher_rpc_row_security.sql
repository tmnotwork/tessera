-- delete_question_if_teacher: 関数実行中は row_security=off を強制し、RLS 下でも DELETE が確実に効くようにする。
-- 教師チェックは関数先頭で維持する。

CREATE OR REPLACE FUNCTION public.delete_question_if_teacher(p_question_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  v_role text;
  v_n int;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION '認証されていません';
  END IF;

  SELECT role INTO v_role FROM public.profiles WHERE id = auth.uid();
  IF v_role IS NULL OR lower(trim(v_role)) <> 'teacher' THEN
    RAISE EXCEPTION '教師のみ問題を削除できます';
  END IF;

  DELETE FROM public.questions WHERE id = p_question_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n > 0;
END;
$$;

ALTER FUNCTION public.delete_question_if_teacher(uuid) OWNER TO postgres;

REVOKE ALL ON FUNCTION public.delete_question_if_teacher(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_question_if_teacher(uuid) TO authenticated;
