-- question_knowledge のうち、questions に存在しない question_id を参照している行を削除
-- （問題を削除したあとに中間テーブルに残った「幽霊」参照で件数が増えるのを防ぐ）
DELETE FROM public.question_knowledge
WHERE question_id NOT IN (SELECT id FROM public.questions);
