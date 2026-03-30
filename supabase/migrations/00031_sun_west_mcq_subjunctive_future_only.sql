-- 四択「If the sun _____ in the west, I would not change my mind.」
-- 誤答から直説法・過去形・過去完了（過去分詞系）を除き、仮定法未来の形のみに統一する。

DO $$
DECLARE
  qid uuid;
BEGIN
  SELECT id INTO qid
  FROM public.questions
  WHERE question_text = 'If the sun _____ in the west, I would not change my mind.'
    AND deleted_at IS NULL
  ORDER BY created_at
  LIMIT 1;

  IF qid IS NULL THEN
    RAISE NOTICE '00031: matching question not found, skipped';
    RETURN;
  END IF;

  DELETE FROM public.question_choices WHERE question_id = qid;

  UPDATE public.questions
  SET
    correct_answer = 'were to rise',
    explanation = '選択肢はすべて仮定法未来（were to / should ＋ 原形）の形にそろえている。'
      '非現実的な「思考実験」には were to が適し、should は万が一の仮定向き。'
      '「太陽が西から昇る」のコロケーションでは動詞は rise。shine は不適。したがって (A) were to rise。',
    updated_at = now()
  WHERE id = qid;

  INSERT INTO public.question_choices (question_id, position, choice_text, is_correct)
  VALUES
    (qid, 1, 'were to rise', true),
    (qid, 2, 'should rise', false),
    (qid, 3, 'were to shine', false),
    (qid, 4, 'should shine', false);
END $$;
