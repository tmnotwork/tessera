-- 仮定法チャプターで「未来の仮定法：should の仮定法・主節の形」までのカードに「基本」タグを付与（未リンクのもののみ）
-- knowledge.content はアプリ上のカード題名（knowledge.json の title）に一致

INSERT INTO public.knowledge_tags (name)
VALUES ('基本')
ON CONFLICT (name) DO NOTHING;

INSERT INTO public.knowledge_card_tags (knowledge_id, tag_id)
SELECT k.id, t.id
FROM public.knowledge k
CROSS JOIN public.knowledge_tags t
WHERE t.name = '基本'
  AND k.unit = '仮定法'
  AND k.content IN (
    '仮定法とは',
    '直説法と仮定法の比較',
    '仮定法の特徴：時制のずれ',
    '仮定法過去（現在の妄想）',
    '仮定法過去（未来の妄想）',
    '仮定法のbe動詞',
    '仮定法過去完了（過去の妄想）',
    '混合仮定法',
    '仮定法未来',
    '仮定法未来(1)were to',
    '仮定法未来(2)should',
    '未来の仮定法：were to と should の違い',
    '未来の仮定法：should の仮定法・主節の形'
  )
ON CONFLICT (knowledge_id, tag_id) DO NOTHING;
