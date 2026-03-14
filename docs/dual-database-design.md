# 双方向デュアルDB実装方針

## 現状の課題

### 現在の構成

| 項目 | 状態 |
|---|---|
| Supabase | フルスキーマ（subjects / knowledge / memorization_cards / questions / tags 等） |
| ローカルSQLite | `knowledge_local` テーブルのみ |
| 同期タイミング | アセットインポート時のみ、一方向 |
| ネット断時の挙動 | 全画面がSupabaseに直接アクセスするためエラー表示のみ |
| リポジトリ層 | なし（全画面が `Supabase.instance.client` を直叩き） |
| connectivity検知 | なし |

---

## 設計方針

### 基本原則

- **オフライン優先（Offline-first）**: ローカルDBを正とし、ネット接続時にSupabaseと双方向同期する
- **Last-Write-Wins**: 競合は `updated_at` の新しい方を優先
- **Web例外**: sqfliteはWeb非対応のためWebはSupabase直接アクセスのみ（Repositoryレイヤーで分岐）

---

## スキーマ設計

### 1. 通常テーブル（エンティティ系）

subjects / knowledge / memorization_cards / questions / question_choices に以下を追加：

```sql
local_id      INTEGER PRIMARY KEY AUTOINCREMENT
supabase_id   TEXT UNIQUE        -- Supabaseの UUID。nullなら未Push
dirty         INTEGER DEFAULT 1  -- 1=変更あり未同期, 0=同期済み
deleted       INTEGER DEFAULT 0  -- ソフトデリート（1=削除済み、Push後に物理削除）
synced_at     TEXT               -- 最後にSupabaseと同期した時刻
created_at    TEXT NOT NULL
updated_at    TEXT NOT NULL
```

### 2. 中間テーブル（junction table系）

`knowledge_card_tags` / `memorization_card_tags` / `question_knowledge` は
自然な単一PKを持たないため、**個別レコードのdirty管理ではなく、親エンティティのsaveと一体で全件置換**する。

- 中間テーブルはローカルに鏡像テーブルを持つ
- 親（knowledge等）がdirty=1になった時点で、対応する中間テーブルもPush対象とみなす
- Push時は「Supabase側を削除→再INSERT」パターンを継続（現在の `syncTags()` の挙動に合わせる）

```sql
-- 例: local_knowledge_card_tags
local_id          INTEGER PRIMARY KEY AUTOINCREMENT
local_knowledge_id INTEGER NOT NULL   -- knowledge.local_id への参照
tag_name          TEXT NOT NULL       -- タグ名をそのまま保持（supabase_idより安定）
supabase_tag_id   TEXT               -- knowledge_tags.id
synced            INTEGER DEFAULT 0
```

### 3. タグマスタテーブル（knowledge_tags / memorization_tags）

ローカルに鏡像テーブルを持つ。タグ名はUNIQUEキーとして扱う（Supabase側も同様）。

---

## SyncMetadataStore

`shared_preferences` に以下を保存：

```
sync.last_pull_at       -- 最終Pull時刻（ISO8601）
sync.is_syncing         -- 同期中フラグ（クラッシュ後のリカバリ用）
```

---

## SyncEngineの設計

`lib/src/sync/sync_engine.dart`

### Pull（Supabase → Local）

```
【初回 / 全件Pull】
1. sync.last_pull_at が null の場合
   → Supabaseの全テーブルを全件取得してローカルに格納（初期化）
   → 既存のknowledge_localデータとsupabase_idで照合してマージ

【差分Pull（2回目以降）】
1. last_pull_at を取得
2. Supabaseから updated_at > last_pull_at のレコードを取得
3. supabase_id で照合:
   - 存在しない              → INSERT（dirty=0）
   - 存在 かつ dirty=0      → 上書きUPDATE
   - 存在 かつ dirty=1（競合）→ updated_at 新しい方を採用。ローカルが古ければ上書き
4. Supabaseで deleted_at が設定されたレコード → ローカルも deleted=1
5. Pull完了後 → last_pull_at = now() を保存
```

> **⚠ Supabase側に `deleted_at` カラムが必要**
> 現在のスキーマにはないため、全テーブルに追加するか、`deleted_records` テーブルを作成する。

### Push（Local → Supabase）

```
【Push順序（FK依存順）】
subjects → knowledge → memorization_cards → questions → question_choices
→ knowledge_tags → knowledge_card_tags
→ memorization_tags → memorization_card_tags
→ question_knowledge

【各エンティティのPush処理】
1. dirty=1 かつ deleted=0 のレコードを取得
   - supabase_id が null → INSERT → 返却されたIDをローカルに保存
   - supabase_id あり    → UPSERT

2. dirty=1 かつ deleted=1 のレコードを取得
   - supabase_id あり → Supabaseから物理削除 → ローカルも物理削除
   - supabase_id なし → ローカルから物理削除（未Push分の削除）

3. 中間テーブルのPush（親エンティティのPushが成功した後）
   - Supabase側の既存中間レコードを削除
   - ローカルの鏡像テーブルから全件INSERT
   - ローカル鏡像テーブルを synced=1 に更新

4. 完了後 → dirty=0, synced_at=now()

【FK未解決の場合】
- 親の supabase_id がまだ null の場合、子のPushはスキップ
  → 次の同期サイクルで再試行
```

### 競合解消

```
競合 = ローカルが dirty=1 かつ Supabase側も updated_at が更新されている場合

解消方針: Last-Write-Wins
  - Supabase.updated_at > Local.updated_at → Supabaseで上書き、dirty=0
  - Local.updated_at >= Supabase.updated_at → ローカルをPush（後述のreorder問題を除く）

競合をユーザーに通知する機構は現フェーズでは不要
```

---

## display_order（並び替え）の特殊処理

**問題**: ドラッグ並び替えは同一subject内の全カードのdisplay_orderを一括更新する。
これを全件dirty=1にすると、Pull時に大量の競合が発生する。

**対応**:
- `display_order` の変更は `updated_at` を更新しない
- Push時は `display_order` のみ更新する別フラグ `order_dirty` を設ける
  または
- Pull/Push時に `display_order` は競合判定から除外し、ローカルの値を優先する

---

## question_choices の delete+reinsert パターン

**問題**: `FourChoiceCreateScreen` は編集時に全choicesを削除→再INSERTする。
これをそのままローカルDBに適用すると、sync管理が複雑になる。

**対応**:
- ローカルDBでも同じく「対象questionの全choices削除→再INSERT」を維持
- question が dirty=1 の場合、Push時に Supabase 側も全choices削除→再INSERT
- question_choices に独立した dirty 管理は不要（question に紐づく）

---

## 初回同期（既存Supabaseデータの取り込み）

初回起動時（`last_pull_at` が null）の処理：

```
1. Supabaseから全テーブル全件取得
2. ローカルDBに全件INSERT（dirty=0）
3. 既存の knowledge_local と supabase_id で照合してマージ
4. last_pull_at = now() を保存
```

これにより、既存のSupabaseデータを失わずにローカルDBを初期化できる。

---

## リポジトリ層の設計

`lib/src/repositories/` 配下に作成。各画面は Repository 経由でのみDBアクセスする。

```dart
// 例
abstract class KnowledgeRepository {
  Future<List<Knowledge>> getBySubject(String subjectId);
  Future<Knowledge> save(Knowledge item); // ローカル書き込み + dirty=1
  Future<void> delete(String id);         // deleted=1 フラグ + dirty=1
}

class KnowledgeRepositoryImpl implements KnowledgeRepository {
  // Web: Supabase直接
  // Mobile/Desktop: ローカルDB書き込み → SyncEngine.pushIfOnline()
}
```

**読み取りはローカル優先**:
- Mobile/Desktop: ローカルDB から読む
- Web: Supabase から直接読む

**書き込みはローカル先書き**:
- Mobile/Desktop: ローカルDB に書く（dirty=1）→ オンラインなら即Push
- Web: Supabase に直接書く

---

## connectivity監視

`connectivity_plus` パッケージを追加（現在 pubspec.yaml に未記載）。

```dart
// オフライン → オンライン復帰時
connectivitySubscription = Connectivity().onConnectivityChanged.listen((result) {
  if (result != ConnectivityResult.none) {
    SyncEngine.instance.sync(); // 差分同期を実行
  }
});
```

---

## UIでの考慮事項

### ローカルDBのデータが画面に反映されるタイミング

| 操作 | 現在 | 実装後 |
|---|---|---|
| 一覧表示 | Supabase直接 | ローカルDB（オフラインでも表示） |
| カード作成 | Supabase INSERT後に一覧リロード | ローカルINSERT後に即反映、バックグラウンドでPush |
| カード編集 | Supabase UPDATE後にリロード | ローカルUPDATE後に即反映 |
| カード削除 | Supabase DELETE後にリロード | ローカルにdeleted=1、UI即反映、バックグラウンドでPush |
| 並び替え | Supabase batch UPDATE後にリロード | ローカル更新後に即反映 |

### 同期中・エラー表示

- 同期中インジケーター（AppBarやSnackBar）を表示
- Push失敗時はローカルに dirty=1 を維持し、次回ネット復帰時に再試行
- 競合発生時は現フェーズでは無音でLast-Write-Wins（将来的に通知追加）

### KnowledgeDetailScreen の一時キャッシュ問題

- 現在 `_savedTitles` 等のメモリキャッシュは保存前にアプリ終了すると消える
- 実装後は「ローカルDBに即保存（dirty=1）」に変更し、自動保存的な挙動にする
- ただし「保存ボタン」の意味は「Supabaseへの確定Push」として残す

---

## Web対応

sqfliteはWebで動作しない。Repositoryレイヤーでプラットフォームを分岐：

```dart
KnowledgeRepository createRepository() {
  if (kIsWeb) {
    return KnowledgeSupabaseRepository(); // Supabase直接
  } else {
    return KnowledgeLocalRepository(localDb, syncEngine); // ローカル優先
  }
}
```

---

## Supabase側スキーマ変更が必要な箇所

| 変更内容 | 対象 | 理由 |
|---|---|---|
| `deleted_at TEXT` カラム追加 | 全テーブル | ソフトデリートをPull時に検知するため |
| または `deleted_records` テーブル作成 | 新規 | 削除されたレコードのtombstone管理 |

---

## 実装ステップ

| ステップ | 内容 | 依存 |
|---|---|---|
| 1 | pubspec.yaml に `connectivity_plus` 追加 | なし |
| 2 | Supabaseスキーマに `deleted_at` 追加（migration作成） | なし |
| 3 | ローカルDB全テーブル追加・マイグレーション機構整備 | なし |
| 4 | `SyncMetadataStore` 実装 | ステップ3 |
| 5 | `LocalDatabase` クラス（CRUD + dirty管理） | ステップ3 |
| 6 | `SyncEngine`（Pull/Push/Conflict/初回全件取込） | ステップ4,5 |
| 7 | 各 `Repository` クラス実装（Web分岐あり） | ステップ5,6 |
| 8 | `connectivity` 監視 + 自動同期トリガー | ステップ6 |
| 9 | 各画面をRepository経由に変更（Supabase直叩き廃止） | ステップ7 |
| 10 | KnowledgeDetailScreenの一時キャッシュをローカル自動保存に変更 | ステップ9 |
| 11 | 既存の `knowledge_local` テーブル + LearningSyncPage（テスト用）を削除 | ステップ9 |

---

## 保留・将来検討事項

- **リアルタイム同期**: Supabase Realtime Subscriptions（複数端末対応時に追加）
- **競合通知UI**: 競合が発生した場合にユーザーが選択できるダイアログ
- **MemorizationCard 詳細・編集画面**: 現在未実装のため、実装時に Repository を使う
- **Supabase RLS / 認証**: 現在は anon 全許可。マルチユーザー対応時に変更
