# 同期がうまくいかないときの確認（開発者向け）

## アプリ側で起きていた問題（修正済み）

### 1. 起動直後の同期が「未ログイン」で走っていた
- `main()` で `SyncEngine.instance.syncIfOnline()` を **ログイン前**に呼んでいた。
- `subjects` / `knowledge` / `questions` などは RLS で **`authenticated` のみ SELECT 可**（00012 マイグレーション）。
- その結果、**空の Pull** や **401 相当の失敗**になりやすかった。
- **対応**: `currentSession != null` のときだけ起動時に `syncIfOnline()` を呼ぶ。

### 2. `onAuthStateChange` の取りこぼし（ログイン済みなのに同期が一度も走らない）
- `RootScaffold` が `appAuthNotifier.listen(_onAuthChanged)` する**より前**に、Supabase が **`initialSession` を流す**と、コールバックが一度も呼ばれない。
- `_onAuthChanged` 内の `syncIfOnline()` がスキップされ、**ローカルに一度も Pull されない**状態になり得た。
- **対応**: 初回フレーム後（`addPostFrameCallback`）に、**ログイン済みなら**もう一度 `syncIfOnline()` を明示的に呼ぶ。

### 3. `syncIfOnline` は例外をほとんど投げない
- `sync()` → `_runSync` は失敗時 **`SyncNotifier.setError`** までして **再スローしない**。
- 呼び出し側の `try/catch` では失敗に気づけない。
- **対応**: デバッグ時は `SyncNotifier.instance.state` / `lastError` を見る。`syncIfOnline` 内でも kDebugMode でログを出す。

### 4. 学習状況（`question_learning_states`）は「同期」と「直接 API」が別経路
- タイル表示は **Supabase を直接 SELECT**。
- 解答後は **`QuestionLearningStateRemote` で直接書き込み** + ローカルは `SyncEngine` の Push 対象。
- **同期だけ**を見ても、サーバーに行が無い原因が別（RLS・マイグレーション未適用など）の場合がある。

### 5. Push が `local_questions.supabase_id` 空で無音スキップされていた
- `_pushQuestionLearningStateRow` は **JOIN 先の `local_questions.supabase_id` が空だと即 return** していた（ログも出さない）。
- その状態でも **解答記録時には画面側で `questionSupabaseId` を知っている**ため、ローカルに **`question_supabase_id` を冗長保持**する（DB v6）。
- **強制同期**でも、行に保存済みの UUID があれば **Push が通る**。

---

## UNIQUE constraint failed: local_question_learning_states (learner_id, question_local_id)

- 端末で解答して **先にローカルに学習状態が作られた**（`supabase_id` がまだ null）あと、**Pull で同じ学習者×問題のリモート行**が来ると、`getBySupabaseId` では既存行にヒットせず **INSERT** しようとして SQLite 2067 になる。
- **対応（アプリ）**: Pull マージ時に `(learner_id, question_local_id)` で既存行を探し、あれば **UPDATE** して `supabase_id` をリモートの `id` で埋める。

## `question_choices.updated_at` does not exist (42703)

- リモートに **`00014_add_deleted_at_for_sync.sql` が未適用**の DB では、当初 `question_choices` に `updated_at` が無い。
- アプリは Pull の並び・増分に **`updated_at` を使っていた**ため、PostgreSQL 42703 になる。
- **対応（アプリ）**: `updated_at` が SELECT に含まれないテーブルは **`created_at` で Pull** するよう修正済み。また 42703 で **legacy 列**にフォールバック。
- **推奨（DB）**: 本番でも `00014` を適用すると、削除同期・`question_choices` の更新追跡が正確になる。

## Supabase / 環境で確認すること

| 確認 | 内容 |
|------|------|
| マイグレーション | `00014`（deleted_at / question_choices の updated_at）・`00017` 等が **接続先**に適用されているか |
| RLS | 学習者は `auth.uid() = learner_id` で自分の行のみ INSERT/UPDATE/SELECT 可 |
| 同一プロジェクト | 端末・アプリの **URL / anon key** が同じか（`.env` と埋め込みフォールバックの取り違えに注意） |
| 増分 Pull | `sync.last_pull_at`（SharedPreferences）が極端に未来だと増分が空になりやすい（端末時刻のずれ） |

---

## 運用での切り分け

1. **強制同期ボタン**（各タブ AppBar の同期アイコン）を押し、SnackBar が成功かエラーかを見る。  
2. デバッグビルドのコンソールで `SyncEngine.sync error` / `syncIfOnline` のログを確認。  
3. Supabase Dashboard の **Table Editor** で `question_learning_states` に行が増えるか確認。
