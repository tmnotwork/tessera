# Supabase とローカル同期 — 現状確認（コードベース）

コードを変えずに仕様を整理したもの。

---

## 1. どこで同期が動くか

| 対象 | 同期の有無 |
|------|------------|
| **Web** | なし。`kIsWeb` のとき SyncEngine は `sync()` / `syncIfOnline()` 内で即 return。sqflite 非対応のためローカル DB も使わない。 |
| **Windows / macOS / モバイル** | あり。起動時にローカル DB（sqflite）を開き、SyncEngine を init して同期する。 |

---

## 2. 同期の流れ（1回の sync）

1. **Pull（先）**  
   - リモート（Supabase）→ ローカル（SQLite）。  
   - `lastPullAt` が無いときは **全件 Pull**（`_pullAll`）、あるときは **増分 Pull**（`updated_at >= lastPullAt` の行だけ `_pullIncremental`）。
2. **Pull 完了時刻を保存**  
   - `SyncMetadataStore.setLastPullAt(pullStartAt)`（SharedPreferences）。
3. **Push（後）**  
   - ローカルで `dirty = 1` の行を Supabase に insert/upsert、`dirty = 1` かつ `deleted = 1` の行はリモートで delete してからローカルから削除。
4. **競合**  
   - コメント上は「LWW（Last Write Wins）」想定。Pull でリモートを優先してローカルを更新し、そのあと Push でローカルの変更を送る。

---

## 3. Pull の対象テーブル

| リモートテーブル | ローカルテーブル | 備考 |
|------------------|------------------|------|
| subjects | local_subjects | 常に Pull（Safe なし） |
| knowledge | local_knowledge | 常に Pull |
| questions | local_questions | 常に Pull |
| memorization_cards | local_memorization_cards | リモートに無ければスキップ（PGRST205） |
| question_choices | local_question_choices | 同上 |
| knowledge_tags | local_knowledge_tags | 同上 |
| memorization_tags | local_memorization_tags | 同上 |
| 中間（knowledge_card_tags, memorization_card_tags, question_knowledge） | 対応するローカル | 初回のみ Full。増分は未実装（コメントどおり）。 |

リモートにテーブルが無い場合はそのテーブルだけスキップして続行。

---

## 4. Push の対象

- subjects, knowledge, questions は常に Push。
- memorization_cards, question_choices はリモートにテーブルが無い場合スキップ（PGRST205）。
- タグ・中間テーブルは「現フェーズではエンティティの Push まで」とコメントあり（`_pushTagsAndJunctions` は中身なし）。

---

## 5. いつ sync が走るか

| タイミング | 場所 |
|------------|------|
| 起動直後（モバイル/デスクトップのみ） | `main()` で `SyncEngine.init` の直後に `syncIfOnline()` を 1 回呼ぶ。 |
| ログイン直後 | `_onAuthChanged()` 内で `SyncEngine.instance.syncIfOnline()`。 |
| オンライン復帰 | Connectivity の変更を listen し、接続回復から 3 秒デバウンス後に `syncIfOnline()`。 |
| 知識カード保存後 | KnowledgeListScreen でカード追加・保存後に `syncIfOnline()`。 |

`syncIfOnline()` は「オンラインなら sync 実行、オフラインなら何もしない」という名前だが、実装は try/catch で失敗時は握りつぶしているだけ。connectivity は「接続あり」のときのトリガー用。

---

## 6. 誰がローカルを見るか

- **SubjectRepository / KnowledgeRepository**  
  - `createSubjectRepository(localDb)` / `createKnowledgeRepository(localDb)` で、  
    **Web または `localDb == null`** → Supabase 直。  
    **モバイル/デスクトップで `localDb != null`** → ローカル DB。
- **KnowledgeDbHomePage（知識DBタブ）**  
  - `widget.localDatabase` を渡しているので、Windows 等では **ローカル** から科目・カードを読む。  
  - カード 0 件のときは、既存対応で KnowledgeListScreen が Supabase にフォールバックして取得している。
- **学習タブ（LearnerHomeScreen）**  
  - KnowledgeListScreen に `localDatabase` を渡していないため、**Supabase 直**。

---

## 7. 初回 Pull と増分 Pull

- **初回**  
  - `SyncMetadataStore.getLastPullAt()` が null/空 → `_pullAll`。  
  - 各テーブルを `select(cols).range(offset, offset+pageSize-1)` で全件取得し、`_mergeRow` でローカルに insert/update。
- **2回目以降**  
  - `lastPullAt` がある → `_pullIncremental`。  
  - `updated_at >= lastPullAt` の行だけ取得して `_mergeRow`。  
  - 中間テーブルは増分未実装（`_pullJunctionIncremental` は空に近い）。

---

## 8. まとめ

- **Web**: 同期なし。常に Supabase 直。
- **Windows/macOS/モバイル**: 起動・ログイン・オンライン復帰・カード保存時に Pull → Push の同期。知識DBタブはローカルを参照し、カードが 0 件のときだけ Supabase にフォールバック。
- **リモートに無いテーブル**: Pull/Push ともスキップして続行。
- **タグ・中間テーブル**: Pull は初回のみ。Push は現状未実装（エンティティまで）。
