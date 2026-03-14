# データベースの整え方（必須・1回だけ）

アプリの「参考書データをインポート」や教師用管理画面を正しく動かすには、**Supabase のデータベースを先に整えておく必要があります。**

## 前提: プロジェクトがオンラインか確認する

1. **Supabase ダッシュボード**を開く  
   https://supabase.com/dashboard → **アプリで使っているプロジェクト**を選択（URL のプロジェクト ID が一致しているか確認）

2. **プロジェクトが「一時停止」になっていないか確認**  
   - 無料枠は一定期間使わないと「Paused」になることがあります。  
   - 画面上に **「Resume project」** が出ていたらクリックして復帰させてください。  
   - 一時停止のままではアプリから接続できず、**SocketException** や接続エラーになります。

3. **API の URL と anon key を確認**  
   - 左メニュー **Settings → API** で **Project URL** と **anon public** キーを確認。  
   - アプリの `lib/main.dart` の `_fallbackSupabaseUrl` / `_fallbackSupabaseAnonKey` または `.env` の `SUPABASE_URL` / `SUPABASE_ANON_KEY` が、このプロジェクトのものと一致しているか確認してください。  
   - 一致していないと接続できません。

## 手順（1回だけ実行）

1. 上記のとおり **対象プロジェクトを開き、一時停止でないことを確認**

2. 左メニューで **「SQL Editor」** を開く

3. **「New query」** で新規クエリを開く

4. プロジェクト内の **`supabase/apply_schema.sql`** を開き、**ファイルの中身をすべてコピー**する

5. SQL エディタに **貼り付けて「Run」** をクリック

6. エラーが出ずに完了すれば完了。  
   （既にテーブルがある場合も、同じファイルを実行して問題ありません。不足している列やポリシーだけ追加されます。）

## このファイルで行うこと

- `subjects`（科目マスタ）の作成
- `knowledge`（知識）の作成（**subject_id 列を含む**）
- 既存の `knowledge` に `subject_id` が無い場合は列の追加
- `questions`（問題）の作成
- RLS ポリシー（anon で読み書き可能・開発用）の設定
- 初回データとして科目「英文法」の登録

## 英文法のデータを一式入れる（アプリのインポートが使えない場合）

アプリから「参考書データをインポート」ができない（接続エラーなど）場合、**コマンドラインで Supabase に英文法の科目＋知識＋問題を投入**できます。

1. 上記のとおり **apply_schema.sql を実行済み**であること
2. プロジェクト直下で:
   ```powershell
   dart run scripts/seed_supabase.dart
   ```
3. 成功すると「subjects: 1」「knowledge(英文法): 55」「questions: 25」のように表示されます。これで Supabase に英文法の一式が入っています。

## 実行後にすること

- アプリで **「参考書データをインポート」** を実行すると、`knowledge` と `questions` にデータが投入されます（既に `scripts/seed_supabase.dart` で投入済みの場合は不要）。
- 教師用管理画面で知識一覧が表示され、追加・編集ができるようになります。

## トラブル時

- **SocketException / ネットワークに接続できません** が出る（Android アプリ）  
  → **Supabase プロジェクトが一時停止（Paused）になっていないか** ダッシュボードで確認し、なっていれば「Resume project」で復帰させてください。  
  → **APK を IPv6 対策オプション付きで再ビルド**する:  
    `flutter build apk --dart-define=dart.library.io.force_staggered_ipv6_lookup=true`  
    または `.\build_android.ps1`（このオプション付きでビルドします）。  
  → アプリの **教師用管理** で **接続テスト**（Wi‑Fiアイコン）を押すと、詳細なエラー内容が表示されます。  
  → **Settings → API** の URL と anon key が、アプリで使っている値と一致しているか確認してください。  
  → `.env` に `localhost` や `127.0.0.1` を入れていないか確認（実機では使えません。アプリは自動でフォールバックURLに切り替えます）。

- **「Could not find the 'subject_id' column」** が出る  
  → 上記のとおり **`supabase/apply_schema.sql` を SQL エディタで実行**してください。  
  実行後、もう一度アプリからインポートを試してください。

- **「科目の取得に失敗しました」** が出る  
  → 同じく `apply_schema.sql` を実行すると、`subjects` テーブルと「英文法」が作成されます。
