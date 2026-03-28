-- 表示名称「ヒント」に合わせて prompt_supplement のカラムコメントを更新する。
-- （00026 適用後に 00026 ファイル側の COMMENT だけ差し替えた環境向け。冪等。）
COMMENT ON COLUMN public.english_examples.prompt_supplement IS 'ヒント（時制・主語・文法指定など、和文だけで曖昧な条件を明示）';
