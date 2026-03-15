# Supabase ↔ ローカルDB 同期 改善ロードマップ

作成日: 2026-03-15
対象: `lib/src/sync/sync_engine.dart` を中心とした同期処理全体

---

## 現状の課題 総括

コード調査の結果、同期エンジンの基本設計（Pull→Push の双方向同期、dirty フラグ、差分取得）は正しく機能している。しかし以下の課題があり、マルチデバイス・マルチユーザー環境での安定稼働には至っていない。

### 課題一覧（優先度順）

| # | 課題 | 深刻度 | 影響範囲 |
|---|------|--------|--------|
| 1 | Push削除のエラーハンドリング欠陥 | 🔴 Critical | データ不整合 |
| 2 | タグ・中間テーブルの Push が未実装 | 🔴 Critical | タグが他デバイスに伝わらない |
| 3 | ローカル削除をSupabase側でも soft delete に統一 | 🟠 High | 削除履歴の消失 |
| 4 | Foreign Key 制約が sqflite で未有効化 | 🟠 High | オフライン時の孤立レコード |
| 5 | Last-Write-Wins の競合解消が不完全 | 🟡 Medium | 同時編集時のデータ上書き |
| 6 | Pagination の完全性保証 | 🟡 Medium | 大量データでレコード落ち |
| 7 | Push 途中失敗時の部分同期 | 🟡 Medium | 再試行時の不整合 |
| 8 | 中間テーブルの差分 Pull が未実装 | 🔵 Low | 効率低下（現状は許容範囲） |
| 9 | Web/Mobile の分岐が UI 層に散在 | 🔵 Low | 保守性低下 |

---

## 方針・原則

1. **データは絶対に勝手に消えない**
   - ユーザーが意図していない削除は、いかなるエラー時も発生してはならない
   - Supabase への反映が確認できるまでローカルの物理削除を行わない

2. **soft delete で削除を一元管理する**
   - ローカル: `deleted=1` + `dirty=1`（Push 待ち）
   - Supabase: `deleted_at` をセット（物理 DELETE は行わない）
   - これにより削除履歴が残り、誤削除のリカバリが可能になる

3. **同期は冪等（何度実行しても結果が同じ）にする**
   - Pull は常に INSERT or UPDATE のみ（削除しない）
   - Push 失敗時はローカルを変更せず次回の同期で再試行

4. **失敗はサイレントに無視しない**
   - `catch (_) {}` による無視は廃止
   - エラーはログに残し、ユーザーに状態を通知する

---

## フェーズ別ロードマップ

---

### Phase 1：データ安全の確立（最優先）

**目標:** いかなる条件でもデータが勝手に消えない状態にする

#### 1-1. Push 削除のエラーハンドリング修正

**対象:** `sync_engine.dart` の `_pushTable()` メソッド（468〜472行）

**現状の問題:**
```dart
// 現在（危険）：Supabase DELETE が失敗してもローカルを物理削除してしまう
try {
  await client.from(remoteTable).delete().eq('id', supabaseId);
} catch (_) {}  // ← エラー無視！
await _localDb.delete(localTable, ...);  // ← 結果に関わらず必ず削除
```

**修正方針:**
```dart
// 修正後：Supabase 側の確認が取れた場合のみローカルも削除
bool supabaseDeleteSucceeded = false;
try {
  await client.from(remoteTable)
      .update({'deleted_at': DateTime.now().toUtc().toIso8601String()})
      .eq('id', supabaseId);  // soft delete に変更（後述の 1-2 と連動）
  supabaseDeleteSucceeded = true;
} catch (e) {
  // 失敗時はローカルを dirty=1, deleted=1 のままにして次回リトライ
  debugPrint('SyncEngine: failed to delete $remoteTable/$supabaseId: $e');
}
if (supabaseDeleteSucceeded) {
  await _localDb.delete(localTable, where: 'local_id = ?', whereArgs: [row['local_id']]);
}
```

#### 1-2. Supabase の削除を soft delete（deleted_at）に統一

**対象:** `sync_engine.dart` の `_pushTable()` 内の DELETE 処理

**現状の問題:**
Push 側は物理 DELETE を使っているのに、Pull 側は `deleted_at` によるソフトデリートを前提に設計されており、Push/Pull の設計が食い違っている。

**修正方針:**
- `client.from(remoteTable).delete()` を廃止
- `client.from(remoteTable).update({'deleted_at': now})` に統一
- これにより Pull 時の `deleted_at` チェックと整合する
- Supabase スキーマの RLS で `deleted_at IS NOT NULL` のレコードを非表示にする

**Supabase スキーマ側:**
- 全テーブルに `deleted_at TIMESTAMPTZ DEFAULT NULL` が存在することを確認（マイグレーション `00014` が適用済みであること）
- Pull の SELECT では `deleted_at` を含めて取得し、ローカルの `deleted=1` に変換する（現状のまま）

#### 1-3. Foreign Key 制約の有効化

**対象:** `main.dart` の `_initLocalDb()` → `openDatabase()` 呼び出し

**修正方針:**
```dart
return openDatabase(
  path,
  version: kLocalDbVersion,
  onCreate: (db, version) async {
    await createLocalSyncTables(db);
  },
  onUpgrade: (db, oldVersion, newVersion) async {
    if (oldVersion < 3) {
      await createLocalSyncTables(db);
    }
  },
  onOpen: (db) async {
    await db.execute('PRAGMA foreign_keys = ON;');  // ← 追加
  },
);
```

これにより、オフライン中の親レコード削除時に子レコードが孤立するのを DB レベルで防止する。

---

### Phase 2：同期範囲の完全化

**目標:** タグを含む全エンティティが双方向に同期される状態にする

#### 2-1. タグ・中間テーブルの Push 実装

**対象:** `sync_engine.dart` の `_pushTagsAndJunctions()`（現在空実装）

**対象テーブル:**
- `local_knowledge_card_tags` → `knowledge_card_tags`
- `local_memorization_card_tags` → `memorization_card_tags`
- `local_question_knowledge` → `question_knowledge`

**実装方針:**

1. ローカルテーブルに `dirty` フラグを追加（現在は `synced` フラグのみ）
   - マイグレーション: `local_knowledge_card_tags` に `dirty INTEGER DEFAULT 1` を追加

2. タグ付け操作（追加・削除）時に `dirty=1` をセット

3. Push 時に `dirty=1` の中間テーブルレコードを Supabase に反映:
   ```dart
   // upsert タグ中間テーブル
   final dirtyCardTags = await _localDb.db.query(
     'local_knowledge_card_tags',
     where: 'dirty = ?',
     whereArgs: [1],
   );
   for (final tag in dirtyCardTags) {
     await client.from('knowledge_card_tags').upsert({
       'knowledge_id': tag['supabase_knowledge_id'],
       'tag_id': tag['supabase_tag_id'],
     });
     await _localDb.db.update(
       'local_knowledge_card_tags',
       {'dirty': 0},
       where: 'local_knowledge_id = ? AND tag_name = ?',
       whereArgs: [tag['local_knowledge_id'], tag['tag_name']],
     );
   }
   ```

4. タグマスタ（`local_knowledge_tags`）の新規タグも Push する

#### 2-2. 中間テーブルの差分 Pull 実装

**対象:** `sync_engine.dart` の `_pullJunctionIncremental()`（現在スキップ）

**現状の問題:**
中間テーブルには `updated_at` がないため差分取得ができず、毎回フル取得になっている。

**修正方針:**
- Supabase の中間テーブルに `created_at TIMESTAMPTZ DEFAULT NOW()` を追加
- `created_at >= lastPullAt` で差分取得する
- または「タグ変更時に親エンティティの `updated_at` を更新する」DB トリガーを追加し、親の差分 Pull で間接的にカバーする

---

### Phase 3：同期品質の向上

**目標:** 複数デバイス・複数ユーザー環境でも正確に同期される状態にする

#### 3-1. Last-Write-Wins の競合解消を改善

**対象:** `sync_engine.dart` の `_mergeRow()` 内の競合判定（212〜218行）

**現状の問題:**
`updated_at` が同一秒の場合、常にローカル優先になる。

**修正方針:**
```dart
if (remoteUpdated.isAfter(localUpdated)) {
  await _updateLocalFromRemote(...);
} else if (remoteUpdated.isAtSameMomentAs(localUpdated)) {
  // Tiebreaker: supabase_id の辞書順で統一（全デバイスで同じ結果になる）
  final remoteId = _str(remote['id']);
  final localSupabaseId = existing['supabase_id']?.toString() ?? '';
  if (remoteId.compareTo(localSupabaseId) > 0) {
    await _updateLocalFromRemote(...);
  }
}
```

#### 3-2. Pagination の安全性向上

**対象:** `sync_engine.dart` の `_pullTableFull()` / `_pullTableIncremental()` 内のページング（172〜181行）

**現状の問題:**
オフセットベースのページングは、取得中にデータが追加されるとレコードが落ちる可能性がある。

**修正方針:**
取得時に `order` を明示して結果の順序を固定する：
```dart
final rows = await client
    .from(remoteTable)
    .select(cols.join(','))
    .gte('updated_at', lastPullAt)        // 差分 Pull の場合
    .order('updated_at', ascending: true)  // ← 追加：同一タイムスタンプも安定化
    .order('id', ascending: true)          // ← 追加：セカンダリソート
    .range(offset, offset + _pageSize - 1);
```

#### 3-3. Push 途中失敗時のリカバリ改善

**対象:** `sync_engine.dart` の `_pushTable()` 内のループ処理（460〜463行）

**現状の問題:**
途中でエラーが発生すると、成功済みの行（dirty=0）と未処理の行（dirty=1）が混在した状態になる。
次回の同期では成功済み行はスキップされるので、最終的には整合するが、不完全な状態が長く続く可能性がある。

**修正方針:**
各行の Push 失敗を個別に catch してスキップし、失敗した行は `dirty=1` のまま次回に持ち越す：
```dart
for (final row in dirty) {
  try {
    await pushOne(client, row);
  } catch (e) {
    // 1行の失敗が全体の Push を止めない
    // dirty=1 のまま次回に再試行
    debugPrint('SyncEngine: push failed for ${localTable}/${row["local_id"]}: $e');
  }
}
```

---

### Phase 4：保守性・可観測性の向上

**目標:** 問題が起きたときに原因がわかる・直せる状態にする

#### 4-1. 同期ログの記録

**新規実装:** 同期の開始・完了・エラーをローカルに記録するテーブル `local_sync_log` を追加

```sql
CREATE TABLE local_sync_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  started_at TEXT,
  finished_at TEXT,
  status TEXT,  -- 'success' | 'error' | 'partial'
  error_message TEXT,
  pulled_count INTEGER,
  pushed_count INTEGER
);
```

#### 4-2. Web/Mobile 分岐のリポジトリ層への集約

**対象:** `knowledge_list_screen.dart` 等の画面コードに散在する `if (kIsWeb)` 分岐

**修正方針:**
`createKnowledgeRepository()` のような Factory 関数を各画面ではなくルートで一元管理し、画面層にはデータソースの違いを露出しない。

#### 4-3. 削除済みレコードの復旧手段の追加

**対象:** 各 Repository の `delete()` メソッド

**修正方針:**
管理者画面向けに `restore(id)` メソッドを追加：
```dart
Future<void> restore(String id) async {
  await _localDb.db.update(
    'local_knowledge',
    {'deleted': 0, 'dirty': 1, 'updated_at': nowUtc()},
    where: 'local_id = ?',
    whereArgs: [localId],
  );
}
```

---

## 実装順序まとめ

```
Phase 1（即着手）
  ├── 1-1. Push削除のエラーハンドリング修正       ← データ安全の最重要修正
  ├── 1-2. Supabase削除を soft delete に統一       ← 1-1 と同時に実装
  └── 1-3. Foreign Key 制約の有効化               ← 数行の変更で完了

Phase 2（Phase 1 完了後）
  ├── 2-1. タグ・中間テーブルの Push 実装         ← 機能的な同期完全化
  └── 2-2. 中間テーブルの差分 Pull 実装           ← 効率化

Phase 3（Phase 2 完了後）
  ├── 3-1. LWW 競合解消の改善                    ← 複数デバイス対応
  ├── 3-2. Pagination の安全性向上               ← 大量データ対応
  └── 3-3. Push 途中失敗時のリカバリ改善          ← 安定性向上

Phase 4（継続的改善）
  ├── 4-1. 同期ログの記録
  ├── 4-2. Web/Mobile 分岐の整理
  └── 4-3. 削除済みレコードの復旧手段
```

---

## 備考：現状で安全が確認できている箇所

以下は調査の結果、**現状すでに安全に実装されている**ことが確認できた箇所：

- **Pull はデータを削除しない** — Insert/Update のみ。例外時も `lastPullAt` を更新せず次回に再取得
- **Pull 失敗でローカルデータが消えることはない** — ページング途中の失敗も同様
- **Supabase が空データを返してもローカルに影響なし** — `break` してスキップ
- **ユーザーが意図した削除の処理経路は正しい** — `softDelete()` → `dirty=1, deleted=1` → Push 待ち
- **オフライン中に作成→削除したレコードは安全** — `supabase_id` が空のため Supabase DELETE をスキップ
- **各 Repository の `delete()` は softDelete のみ** — 物理削除は Push 完了後のみ
