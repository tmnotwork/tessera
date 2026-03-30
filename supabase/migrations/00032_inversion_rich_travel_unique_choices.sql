-- 「_____ rich, I would travel the world.」
-- If I were と Were I が両立して正解が一意にならないため、誤答を差し替え、解説を更新する。

DO $$
DECLARE
  qid uuid;
BEGIN
  SELECT id INTO qid
  FROM public.questions
  WHERE question_text = '_____ rich, I would travel the world.'
    AND deleted_at IS NULL
  ORDER BY created_at
  LIMIT 1;

  IF qid IS NULL THEN
    RAISE NOTICE '00032: matching question not found, skipped';
    RETURN;
  END IF;

  DELETE FROM public.question_choices WHERE question_id = qid;

  UPDATE public.questions
  SET
    correct_answer = 'Were I',
    explanation = '知識カードのポイントは、if を付けずに were と主語を倒置して条件を文頭に置く形（Were I rich = If I were rich）。'
      '空欄に続くのは rich なので、倒置の Were I だけが「金持ちなら」として成立する。'
      'If I was は仮定法では were が標準で、この倒置形の書き方でもない。'
      'Had I のあとに形容詞 rich だけを続ける形は成立しない（完了仮定なら been などが要る）。'
      'Was I を文頭に置いても、この主節 would travel とつながる倒置の条件節にならない。したがって (B) Were I。',
    updated_at = now()
  WHERE id = qid;

  INSERT INTO public.question_choices (question_id, position, choice_text, is_correct)
  VALUES
    (qid, 1, 'If I was', false),
    (qid, 2, 'Were I', true),
    (qid, 3, 'Had I', false),
    (qid, 4, 'Was I', false);
END $$;
