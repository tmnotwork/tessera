-- 「_____ your help, I would have failed.」の選択肢を Under / Without / Because / If に更新。
-- 00035 を古い内容のまま適用済みの DB 向け（再実行は冪等）。

DO $$
DECLARE
  qid uuid;
BEGIN
  SELECT id INTO qid
  FROM public.questions
  WHERE question_text = '_____ your help, I would have failed.'
    AND deleted_at IS NULL
  ORDER BY created_at
  LIMIT 1;

  IF qid IS NULL THEN
    RAISE NOTICE '00036: matching question not found, skipped';
    RETURN;
  END IF;

  DELETE FROM public.question_choices WHERE question_id = qid;

  UPDATE public.questions
  SET
    correct_answer = 'Without',
    explanation = '空欄の直後は名詞句 your help。Under your help は英語として自然なコロケーションにならない（under guidance などはあるが help とは組み合わせない）。'
      'Because／If のあとには主語＋動詞の節が来るのが基本で、your help だけでは節にならず文として成立しにくい。'
      '前置詞 Without だけが名詞句とつながり「〜がない状態を条件に」という用法になる。Without your help = If I had not had your help。',
    updated_at = now()
  WHERE id = qid;

  INSERT INTO public.question_choices (question_id, position, choice_text, is_correct)
  VALUES
    (qid, 1, 'Under', false),
    (qid, 2, 'Without', true),
    (qid, 3, 'Because', false),
    (qid, 4, 'If', false);
END $$;
