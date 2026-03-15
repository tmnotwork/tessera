# Supabase 状況確認結果（MCP 実施）

確認日: 2025-03-15  
接続先: **https://wnufzrehvhcwclnwxwim.supabase.co**（MCP project-0-learning_platform-supabase）

---

## 1. マイグレーション

| version         | name                          |
|-----------------|-------------------------------|
| 20260313233948  | add_subject_id_to_knowledge   |
| 20260314000444  | add_knowledge_card_fields     |
| 20260315001347  | add_questions_reference       |
| 20260315070502  | ensure_profile_for_existing_user |

→ **ensure_profile_for_existing_user**（00013 相当）は適用済み。

---

## 2. テーブル・件数

| テーブル   | RLS   | 行数 |
|-----------|-------|------|
| subjects  | 有効  | **1** |
| profiles  | 無効  | **1** |
| knowledge | 有効  | 56   |
| questions | 有効  | 43   |

- **subjects**: 1 件（`id`, `name`, `display_order`）→ 例: 英文法
- **profiles**: 1 件（`id`, `role`, `display_name`, created_at, updated_at）  
  - **user_id カラムは存在しない**（リポジトリの 00012 の profiles とはスキーマが一部異なる）
  - 1 行: role=**teacher**, display_name=tmnorwork@gmail.com

---

## 3. subjects の RLS ポリシー（重要）

現在、**anon 用ポリシーのみ**が設定されています。

| ポリシー名              | ロール | 操作   |
|-------------------------|--------|--------|
| subjects: anon select   | anon   | SELECT |
| subjects: anon insert   | anon   | INSERT |
| subjects: anon update   | anon   | UPDATE |
| subjects: anon delete   | anon   | DELETE |

→ **00012（add_profiles_and_roles）の「anon 削除 → authenticated のみ」への変更は、このプロジェクトには未適用**です。  
つまり **未ログイン（anon）でも subjects は読める状態**です。

---

## 4. 関数

- **ensure_my_profile**: 存在する（00013 相当で作成）
- **get_my_role**: **存在しない**  
  → 00012 で定義する `get_my_role()` が未デプロイのため、00012 の RLS（teacher/learner 用）はこのプロジェクトでは使えません。

---

## 5. 結論と推奨

- **データ**: subjects 1 件・profiles 1 件（教師）・knowledge 56 件あり。**データ的には教材は見える前提**です。
- **RLS**: いまは anon のままなので、**アプリがこの URL に接続していれば、未ログインでも subjects は取得できる**想定です。
- **「ログインしても見えない」が起きる場合の候補**:
  1. アプリの接続先が **このプロジェクトと違う**（別 URL/キー）
  2. ネットワーク／タイムアウトなど

**推奨**:

1. アプリの `.env`（または Supabase 設定）の **SUPABASE_URL** が  
   `https://wnufzrehvhcwclnwxwim.supabase.co` か確認する。
2. 本番で「認証済みだけが教材を見る」にしたい場合は、リポジトリの **00012_add_profiles_and_roles.sql** をこのプロジェクトに適用する（その前に `get_my_role` 作成と profiles の user_id 有無の整合を確認すること）。

以上が MCP で実施した Supabase 状況確認の結果です。

---

## 「ログインしたが科目が0件です」と出るとき

- このプロジェクト（**wnufzrehvhcwclnwxwim**）には **subjects が 1 件** あります（MCP で再確認済み）。
- 0 件と出る = **アプリが別の Supabase に接続している**可能性が高いです。

**確認すること**

1. **Web で動かしている場合**  
   アプリは `https://wnufzrehvhcwclnwxwim.supabase.co` に固定で接続しています。  
   それでも 0 件なら、ブラウザのキャッシュ削除やハードリロードを試してください。

2. **実機・エミュレータで動かしている場合**  
   - プロジェクトルートに **`.env`** がありますか？  
   - ある場合、**SUPABASE_URL** の値を確認してください。  
   - `https://wnufzrehvhcwclnwxwim.supabase.co` 以外（localhost や別プロジェクトの URL）だと、その DB の subjects が空なら 0 件になります。
   - **対処**: `.env` を一時的にリネーム（例: `.env.bak`）してから起動すると、埋め込みの接続先（上記 URL）になり、科目 1 件が表示されるか確認できます。

3. **接続先の Dashboard で確認**  
   - 実際に接続している Supabase の Dashboard → Table Editor → **subjects** を開く。  
   - 行が 0 件なら、そのプロジェクトに科目データを入れるか、アプリの接続先を「subjects にデータがあるプロジェクト」に合わせてください。

---

## Windows アプリで「科目が0件です」と出るとき

Windows アプリ（`flutter run -d windows`）では、**プロジェクトルートの `.env` があればそこから SUPABASE_URL / SUPABASE_ANON_KEY を読んで接続**します。`.env` が無いときだけ、コードに埋め込んだ接続先（`https://wnufzrehvhcwclnwxwim.supabase.co`）を使います。

**科目が 1 件入っている接続先を使う手順**

1. **プロジェクトルート**（`learning_platform` フォルダ）に **`.env`** があるか確認する。
2. **`.env` がある場合**
   - 中身の **SUPABASE_URL** を次のようにする（科目 1 件があるプロジェクト）。
     ```env
     SUPABASE_URL=https://wnufzrehvhcwclnwxwim.supabase.co
     SUPABASE_ANON_KEY=<このプロジェクトの anon key>
     ```
   - **anon key** は、Supabase Dashboard → **Project Settings → API** の「Project API keys」の **anon public** をコピーして貼る。
   - 別プロジェクト用の key を入れていると、そのプロジェクトの subjects が空なら 0 件になる。
3. **`.env` をいったん使わないで試す**
   - `.env` をリネーム（例: `.env.bak`）してから `flutter run -d windows` で起動する。
   - 接続先が埋め込みの `wnufzrehvhcwclnwxwim` になり、科目が 1 件表示されれば、「今の .env の接続先が別プロジェクトだった」と分かる。
4. そのうえで、**普段使いたい接続先**に合わせて、
   - データがある方の URL/key を `.env` に書く、または
   - そのプロジェクトの **subjects** に 1 件以上データを入れる。
