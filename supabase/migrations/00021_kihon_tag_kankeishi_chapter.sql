-- 「関係詞」チャプターの全知識カードに「基本」タグを付与（未リンクのもののみ）

INSERT INTO public.knowledge_tags (name)
VALUES ('基本')
ON CONFLICT (name) DO NOTHING;

INSERT INTO public.knowledge_card_tags (knowledge_id, tag_id)
SELECT k.id, t.id
FROM public.knowledge k
CROSS JOIN public.knowledge_tags t
WHERE t.name = '基本'
  AND k.unit = '関係詞'
  AND k.deleted_at IS NULL
ON CONFLICT (knowledge_id, tag_id) DO NOTHING;
