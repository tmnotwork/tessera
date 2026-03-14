# 双方向デュアルDB実装方針

## 現状の課題

現在の構成は「片方向・部分的」な状態です：

- **Supabase**: フルスキーマ（subjects / knowledge / memorization_cards / questions / tags）
- **ローカルSQLite**: `knowledge_local` のみ、`synced` フラグはあるが実質的な同期機構なし
- **同期タイミング**: アセットインポート時のみの一方向

---

## 設計方針

### 1. スキーマ統一（ローカルをSupabaseに合わせる）

ローカルSQLiteにSupabaseと同等のテーブルを作る。全テーブルに以下の列を追加する：

```sql
supabase_id   TEXT UNIQUE        -- Supabase側のUUID（nullなら未同期）
local_id      INTEGER PRIMARY KEY -- ローカルのオートインクリメントID
dirty         INTEGER DEFAULT 1   -- 1=変更あり未同期, 0=同期済み
deleted       INTEGER DEFAULT 0   -- ソフトデリート（1=削除済み）
synced_at     TEXT               -- 最後にSupabaseと同期した時刻
created_at    TEXT
updated_at    TEXT
```

対象テーブル：

| テーブル | 用途 |
|---|---|
| `subjects` | 科目マスタ |
| `knowledge` | 知識カード |
| `memorization_cards` | 暗記カード |
| `questions` | 設問 |
| `question_choices` | 四択選択肢 |
| `knowledge_tags` / `memorization_tags` | タグマスタ |
| `knowledge_card_tags` / `memorization_card_tags` | タグ中間テーブル |

---

### 2. SyncEngine（同期エンジン）の設計

`lib/src/sync/sync_engine.dart` として専用クラスを実装する。

#### 基本方針

- **オフライン優先（Offline-first）** を基本とする
- ネット接続時に双方向差分同期を実行
- 競合（conflict）は **`updated_at` の新しい方を優先**（Last-Write-Wins）

#### 同期フロー

```
起動時
 └─ ネット接続あり?
     ├─ YES → Pull（Supabase→Local）→ Push（Local→Supabase）→ 差分解消
     └─ NO  → ローカルのみで動作、dirtyフラグを立てながら変更を蓄積

操作時
 └─ CRUD操作 → 必ずLocalに書く（dirty=1）
     └─ ネット接続あり → Supabaseにも即時反映 → dirty=0, synced_at更新

バックグラウンド
 └─ ネット状態変化を監視（connectivity_plus）
     └─ オフライン→オンライン復帰時 → dirty=1のレコードをまとめてPush
```

---

### 3. リポジトリ層の導入

各エンティティにリポジトリクラスを作り、データの読み書き口を一本化する。

```dart
abstract class KnowledgeRepository {
  Future<List<Knowledge>> getAll(String subjectId);
  Future<Knowledge> save(Knowledge item);
  Future<void> delete(String id);
}

class KnowledgeRepositoryImpl implements KnowledgeRepository {
  final LocalDb _local;
  final SupabaseClient _supabase;
  final SyncEngine _sync;

  // 読み取り → ローカル優先
  // 書き込み → ローカル書き → ネットあれば同期
}
```

---

### 4. 差分同期アルゴリズム

#### Pull（Supabase → Local）

```
1. ローカルの最終同期時刻（last_pull_at）を取得
2. Supabaseから updated_at > last_pull_at のレコードを取得
3. ローカルに対応するレコードが存在するか確認（supabase_id で照合）
   - 存在しない           → INSERT
   - 存在する             → updated_at を比較
     - Supabase側が新しい かつ dirty=0 → UPDATE
     - ローカルが dirty=1（競合）      → updated_at 新しい方を採用
4. Supabaseで削除されたレコード → tombstone で検知 → ローカルもソフトデリート
```

#### Push（Local → Supabase）

```
1. dirty=1 のレコードを全取得
2. supabase_id が null    → Supabaseにinsert → supabase_idをローカルに保存
3. supabase_id あり        → Supabaseにupsert（updated_atで競合確認）
4. deleted=1 かつ supabase_id あり → Supabaseから削除
5. 完了後 → dirty=0, synced_at=now() に更新
```

---

### 5. 削除の扱い（ソフトデリート）

物理削除せずに `deleted=1` フラグを立てる。これにより：

- オフライン中の削除をPush時にSupabaseへ反映できる
- Pull時にSupabase側の削除も検知できる（tombstoneパターン）

Supabase側には `deleted_at` カラムを追加するか、専用の `deleted_records` テーブルで管理する。

---

### 6. 依存関係の同期順序

親→子の順でPush、子→親の順でPullする：

```
Push順: subjects → knowledge → memorization_cards → questions → question_choices → tags
Pull順: subjects → knowledge → memorization_cards → questions → question_choices → tags
```

---

## 実装ステップ

| ステップ | 内容 |
|---|---|
| 1 | ローカルDBスキーマ拡張 — 全テーブル追加、マイグレーション機構を整備 |
| 2 | `SyncMetadataStore` — `last_pull_at` などのメタデータ管理 |
| 3 | `LocalDatabase` クラス — テーブルごとのCRUD、dirty管理を一元化 |
| 4 | `SyncEngine` — Pull / Push / Conflict解消ロジック |
| 5 | 各 `Repository` クラス — 既存のSupabase直叩きコードをリプレイス |
| 6 | connectivity監視 — ネット復帰時の自動同期トリガー |
| 7 | 既存画面のリファクタ — `SupabaseClient` 直接呼び出し → Repository経由に変更 |

---

## 保留・検討事項

- **リアルタイム同期**: Supabaseのrealtime subscriptionsは現状不要。複数端末対応が必要になった場合に追加する
- **タグ系テーブルの同期**: junction tableのためsupabase_idより複合キーで照合する
- **Web対応**: sqfliteはWebで動作しない。WebはSupabase直接のみとし、Repository層で分岐する
