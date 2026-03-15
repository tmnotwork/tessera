# 教材が読み取れないバグ — コード・DB から確定できること

推測を排し、リポジトリのコードと Supabase マイグレーションの定義のみから分かる事実をまとめる。

---

## 1. Supabase RLS（マイグレーション 00012 適用時）

**ファイル:** `supabase/migrations/00012_add_profiles_and_roles.sql`

### subjects

| ポリシー | ロール | 操作 | 条件 |
|----------|--------|------|------|
| `subjects: teacher all` | **authenticated** | ALL | `get_my_role() = 'teacher'` |
| `subjects: learner read` | **authenticated** | SELECT | `USING (true)` |

- `subjects: anon select` 等は **DROP 済み**。anon 用のポリシーは存在しない。

### knowledge

| ポリシー | ロール | 操作 | 条件 |
|----------|--------|------|------|
| `knowledge: teacher all` | **authenticated** | ALL | `get_my_role() = 'teacher'` |
| `knowledge: learner read` | **authenticated** | SELECT | `USING (true)` |

- 同様に anon 用ポリシーは **DROP 済み**。

**確定事実:**  
マイグレーション 00012 が適用されている DB では、`public.subjects` と `public.knowledge` に対して **anon では SELECT できない**。SELECT 可能なのは **authenticated（有効な JWT 付きリクエスト）のみ**。

---

## 2. アプリ側のクライアント利用

**検索結果:** 教材（subjects / knowledge）の取得はすべて `Supabase.instance.client` 経由。

- `lib/main.dart` — 教師タブの科目取得・科目チェック・KnowledgeDbHomePage 内など
- `lib/src/screens/learner_home_screen.dart` — 学習者ホームの科目取得
- `lib/src/repositories/subject_repository.dart` — SubjectRepositorySupabase
- `lib/src/repositories/knowledge_repository.dart` — KnowledgeRepositorySupabase
- `lib/src/screens/knowledge_list_screen.dart` 他、多数

**確定事実:**  
別クライアントや「anon 専用」の使い分けはない。**教材取得はすべて同一の `Supabase.instance.client` で行われている。**

---

## 3. 認証状態と画面表示の順序

**ファイル:** `lib/main.dart`

- `_authReady` が `false` の間は `build` でローディング表示となり、`LearnerHomeScreen` は表示されない（469–471 行付近）。
- `_authReady` が `true` になるのは **`_refreshRole()` 内の `setState` の後** のみ（364–368 行）。
- `_refreshRole()` の流れ:
  1. `await appAuthNotifier.fetchRole()`（`profiles` 参照、要 authenticated）
  2. ログイン中なら `Supabase.instance.client.from('subjects').select('id').limit(10)` を実行（343–348 行）
  3. 最後に `setState(() { _role, _authReady = true, _postLoginSubjectsCheck })`（364–368 行）

**確定事実:**  
**`LearnerHomeScreen` が一度でも表示される時点で、少なくとも 1 回は `_refreshRole()` 内の `subjects` の select が実行済み**である。  
また、教材取得はすべて上記と同じ `Supabase.instance.client` を使っている。

---

## 4. 「ログインしているのに教材が読めない」ときの必要条件（RLS 側）

- RLS 上、subjects / knowledge の SELECT が許されるのは **authenticated** のみ。
- したがって、リクエストが **anon**（有効な JWT が付いていない）として扱われた場合、RLS により **必ず** 読み取りは拒否される。

**確定事実（コード・DBから言えること）:**  
「ログインしているのに教材が読めない」という事象が起きているなら、**その失敗しているリクエストは Supabase 上では anon（未認証）として評価されている**。  
逆に言えば、**リクエストが authenticated として届いていれば、RLS 定義上は subjects / knowledge の SELECT は許可される**（学習者は `learner read` の `USING (true)` で可）。

---

## 5. コード・DB からは「なぜ」は特定できないこと

- **なぜ** ログイン後に一部（または全部）のリクエストが anon として送られているか（セッション未設定・永続化の遅延・Web のストレージ制限など）は、**リポジトリのコードとマイグレーションの定義だけでは特定できない**。
- 実際のプロジェクトで **00012 が適用されているか** は、Supabase Dashboard や `supabase migration list` 等で確認する必要がある。適用されていなければ、DB の RLS はこのドキュメントと異なる。

---

## 6. まとめ（推測なしで言えること）

| 項目 | 内容 |
|------|------|
| RLS | 00012 適用時、subjects / knowledge に anon の SELECT は存在しない。authenticated のみ可。 |
| アプリ | 教材取得はすべて `Supabase.instance.client` から。anon 専用クライアントは使っていない。 |
| 表示順 | LearnerHomeScreen 表示前に、`_refreshRole()` 内で少なくとも 1 回 subjects の select が実行される。 |
| 失敗の必要条件 | 教材取得に失敗しているリクエストは、Supabase 側では **anon（未認証）として評価されている**。 |
| 原因の特定 | 「なぜ anon で送られているか」はコード・マイグレーションのみでは確定できない。 |

原因を「確定」するには、実機・ブラウザでの再現と、失敗時のネットワーク（Authorization ヘッダの有無）や Supabase のログ確認が必要である。
