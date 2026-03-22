# ローカルデータキャッシュ 実装手順書

## 重要原則：Supabase への変更は AI（実施者）が必ず行う

この実装のなかで Supabase 側の変更（テーブル定義変更・マイグレーション・RLS ポリシー・Edge Function など）が必要になった場合、**人手を介さず AI（実施者）が直接実施することがマスト**。

理由：
- Flutter 側のコード変更と Supabase 側の変更は不可分であり、両者のタイミングがずれると動作不整合が発生する
- 手動手順を人間に委ねると、作業抜け・誤りが混入しやすい
- Pull/Push の対象テーブルが増える場合、リモートスキーマとローカルスキーマの整合を AI が一括で保証する必要がある

具体的に AI が担当する Supabase 作業（発生した都度、その場で実施する）:

| タイミング | 作業内容 |
|---|---|
| フェーズ1実施時 | `english_examples`・`english_example_learning_states` テーブルの存在確認と、必要なら RLS ポリシーの追加 |
| フェーズ2実施時 | Pull 対象テーブルに `updated_at`・`deleted_at` カラムが存在するか確認し、欠けていれば `ALTER TABLE` を実行 |
| Pull/Push 動作確認時 | Supabase Dashboard または CLI を使ってデータの疎通を確認 |
| RLS 起因のエラー発生時 | ポリシーを調査・修正 |

**人間は Supabase の手動操作を一切行わない前提で手順書は書かれている。**

---

## 前提：現状の把握

コード調査の結果、以下の状態が明らかになった。

### すでに動いている部分（変更不要）
- `local_question_learning_states` テーブルは存在し、四択解答はローカルに書き込まれている
- `SyncEngine` の Pull/Push ロジックは四択学習状態を含めて機能している
- `KnowledgeRepositoryLocal` は `local_knowledge` を正しく読んでいる

### 問題のある部分（要対応）

| 問題 | 影響範囲 | 深刻度 |
|---|---|---|
| 英語例文がローカルDBに存在しない | `english_example_*` 系画面すべて | 高 |
| 英語例文学習状態がローカルDBに存在しない | 例文進捗、例文練習 | 高 |
| ホーム画面がSupabaseからサブジェクトを取得 | `learner_home_screen.dart` | 中 |
| 四択問題画面がSupabaseから問題を取得 | `question_solve_screen.dart` | 中 |
| 四択進捗画面がSupabaseから学習状態を取得 | `four_choice_progress_screen.dart` | 中 |
| 例文進捗画面がSupabaseから学習状態を取得 | `english_example_progress_screen.dart` | 中 |

---

## フェーズ1：DBスキーマ拡張

**ファイル:** `lib/src/database/local_db.dart`

英語例文と例文学習状態のローカルテーブルが存在しない。これが最初のボトルネック。スキーマに2テーブルを追加し、DBバージョンを9に上げる。

### 変更内容

`kLocalDbVersion` を `8` から `9` に変更する。

`createLocalSyncTables()` に以下を追加する。

```dart
// 13) 英語例文
await db.execute('''
  CREATE TABLE IF NOT EXISTS local_english_examples (
    local_id INTEGER PRIMARY KEY AUTOINCREMENT,
    supabase_id TEXT UNIQUE,
    dirty INTEGER NOT NULL DEFAULT 1,
    deleted INTEGER NOT NULL DEFAULT 0,
    synced_at TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    knowledge_local_id INTEGER,
    english_text TEXT NOT NULL,
    japanese_text TEXT,
    display_order INTEGER,
    FOREIGN KEY (knowledge_local_id) REFERENCES local_knowledge(local_id)
  )
''');

// 14) 英語例文学習状態
await db.execute('''
  CREATE TABLE IF NOT EXISTS local_english_example_learning_states (
    local_id INTEGER PRIMARY KEY AUTOINCREMENT,
    supabase_id TEXT UNIQUE,
    dirty INTEGER NOT NULL DEFAULT 1,
    deleted INTEGER NOT NULL DEFAULT 0,
    synced_at TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    learner_id TEXT NOT NULL,
    example_local_id INTEGER NOT NULL,
    example_supabase_id TEXT,
    repetitions INTEGER NOT NULL DEFAULT 0,
    e_factor REAL NOT NULL DEFAULT 2.5,
    interval_days INTEGER NOT NULL DEFAULT 0,
    next_review_at TEXT NOT NULL,
    last_quality INTEGER,
    reviewed_count INTEGER NOT NULL DEFAULT 0,
    FOREIGN KEY (example_local_id) REFERENCES local_english_examples(local_id),
    UNIQUE (learner_id, example_local_id)
  )
''');
```

インデックスも追加する。

```dart
await db.execute('CREATE INDEX IF NOT EXISTS ix_local_english_examples_supabase_id ON local_english_examples(supabase_id)');
await db.execute('CREATE INDEX IF NOT EXISTS ix_local_english_example_learning_states_supabase_id ON local_english_example_learning_states(supabase_id)');
await db.execute('CREATE INDEX IF NOT EXISTS ix_local_english_example_learning_states_due ON local_english_example_learning_states(learner_id, next_review_at)');
```

**マイグレーション:** `onUpgrade` にバージョン8→9のケースを追加し、既存ユーザーが起動時にテーブルを取得できるようにする。

`LocalTable` クラスに定数を追加する。

```dart
static const englishExamples = 'local_english_examples';
static const englishExampleLearningStates = 'local_english_example_learning_states';
```

---

## フェーズ2：SyncEngineへの英語例文 Pull/Push 追加

**ファイル:** `lib/src/sync/sync_engine.dart`

英語例文と例文学習状態を Pull/Push の対象に追加する。
既存の `local_questions` や `local_question_learning_states` の処理をパターンとして踏襲する。

### Pull の追加

`_pullAll()` と `_pullIncremental()` の両方に `english_examples` テーブルの Pull 処理を追加する。
`knowledge_id` → `knowledge_local_id` の外部キー解決が必要な点は `questions` と同様。

`english_example_learning_states` の Pull は学習状態のため、`learner_id = currentUser.id` でフィルタして自分の分だけ取得する。
これも `question_learning_states` の Pull 処理と同じパターン。

### Push の追加

`_runSync()` の Push フェーズに以下を追加する。

1. `local_english_examples` の dirty=1 行を Push（コンテンツは教師が書くため Push は基本不要だが、将来のため一貫して追加）
2. `local_english_example_learning_states` の dirty=1 行を Push

Push 時のペイロードは `EnglishExampleLearningStateRemote.upsertState()` の引数形式に合わせる。
`reviewed_count` はローカルの値をそのまま使い、リモートを上書きする（ローカルを正とするポリシー）。

### 解答記録メソッドの追加

`SyncEngine` に `recordEnglishExampleLearningProgress()` を追加する。
現在 `EnglishExampleLearningStateRemote.upsertState()` が行っている SM-2 計算をローカルで実行し、`local_english_example_learning_states` に保存する。

```
引数:
  learnerId, exampleSupabaseId, quality (1〜5)

処理:
  1. local_english_examples から example_local_id を取得
  2. local_english_example_learning_states の既存行を取得
  3. SM-2 計算（Sm2Calculator.calculate() を使用）
  4. insertWithSync または updateWithSync（dirty=1）
  5. return true
```

---

## フェーズ3：バックグラウンド同期ヘルパーの作成

**新規ファイル:** `lib/src/sync/background_sync.dart`

現在 `ensureSyncedForLocalRead()` は同期完了まで `await` で待つ。これをバックグラウンド起動に切り替えるヘルパーを作る。
`ensureSyncedForLocalRead()` は残しておき、既存の教師側画面（コンテンツ編集）ではそのまま使い続ける。

```dart
/// ローカルDBを読む前にバックグラウンドで同期を開始する。
/// 同期完了を待たない。呼び出し後すぐに次の処理（ローカル読み取り）に進む。
void triggerBackgroundSync() {
  if (kIsWeb) return;
  if (!SyncEngine.isInitialized) return;
  // unawaited で意図的に待たない
  unawaited(SyncEngine.instance.syncIfOnline());
}
```

このヘルパーを以下の画面で `ensureSyncedForLocalRead()` の代わりに使う（教師側は除く）。

---

## フェーズ4：学習者ホーム画面

**ファイル:** `lib/src/screens/learner_home_screen.dart`

### 現状
`_fetchSubjects()` が `ensureSyncedForLocalRead()` で同期完了を待ち、その後 `Supabase.instance.client.from('subjects')` でリモートから取得している。

### 変更後の流れ

```
triggerBackgroundSync() を呼ぶ（待たない）
  ↓
local_subjects を SQLite から直接取得
  ↓
setState() で即時表示（ここまでが瞬時）
  ↓ （バックグラウンドで同期が走っている）
SyncNotifier の変化を listen して同期完了後に再読み込み
```

### 実装ポイント

- `SubjectRepositoryLocal.getSubjectsOrderByDisplayOrder()` がすでに `local_subjects` を読む実装になっている。これを呼べばよい。
- `initState()` で `SyncNotifier.instance.addListener(_onSyncDone)` を登録し、`done` になったら `_fetchSubjects()` を再呼び出しする。
- リモート直接アクセスを削除し、`SubjectRepositoryLocal` 経由に統一する。
- キャッシュがない初回（local_subjects が空）は通常のローディング表示のまま同期完了を待つ。

---

## フェーズ5：四択問題画面

**ファイル:** `lib/src/screens/question_solve_screen.dart`

### 現状（読み取り）
`_loadQuestion()` が `ensureSyncedForLocalRead()` で待ち、`Supabase` から `questions` と `question_choices` を取得している。

### 変更後（読み取り）

```
triggerBackgroundSync() を呼ぶ（待たない）
  ↓
local_questions, local_question_choices を SQLite から取得
  ↓
即時表示
```

`LocalDatabase.db.query('local_questions', ...)` で `supabase_id = questionId` を検索する。
選択肢は `local_question_choices` を `question_local_id` で JOIN する。

### 現状（SM-2 書き込み）
`_recordLearningProgress()` が以下の2つを同時に行っている。

1. `SyncEngine.recordQuestionLearningProgress()` → ローカルに保存（すでに正しい）
2. `QuestionLearningStateRemote.upsertState()` → リモートへ即時送信

### 変更後（SM-2 書き込み）

ローカル保存はそのまま。リモート送信をバックグラウンドに変更する。

```dart
// ローカルに保存（await する）
final saved = await SyncEngine.instance.recordQuestionLearningProgress(...);

// リモートへの送信はバックグラウンドで（await しない）
if (saved) {
  unawaited(_pushLearningStateToRemote());
}
```

リモート送信が失敗しても dirty=1 が残るため、次回の `SyncEngine.sync()` で補完される。

### 現状（SM-2 読み取り）

学習状態は Supabase から取得している箇所がある。これを `local_question_learning_states` から読む形に変更する。

---

## フェーズ6：英語例文一覧画面

**ファイル:** `lib/src/screens/english_example_list_screen.dart`

### 現状
`ensureSyncedForLocalRead()` で待ち、Supabase から `english_examples` を取得している。

### 変更後

```
triggerBackgroundSync() を呼ぶ（待たない）
  ↓
local_english_examples を SQLite から取得
  ↓
即時表示
```

フェーズ1でテーブルが追加され、フェーズ2でPullが実装されていれば、後はクエリを変えるだけ。

---

## フェーズ7：英語例文練習画面

**ファイル:** `lib/src/screens/english_example_solve_screen.dart`

これが最も変更が大きい画面。現状はリモートのみで完結していて、ローカルが一切関与していない。

### 現状（読み取り）
Supabase から `english_example_learning_states` を取得している（`_statesCache` でセッション内はキャッシュしている）。

### 変更後（読み取り）

```
local_english_example_learning_states を SQLite から取得（フェーズ1で追加済み）
  ↓
_statesCache に格納して既存の仕組みをそのまま活用
```

### 現状（書き込み）
`EnglishExampleLearningStateRemote.upsertState()` をリモートへ直接送っている。ローカル保存なし。

### 変更後（書き込み）

```
SyncEngine.recordEnglishExampleLearningProgress() でローカルに保存（フェーズ2で追加）
  ↓
_statesCache も更新（画面内のセッションキャッシュ）
  ↓ バックグラウンドで
EnglishExampleLearningStateRemote.upsertState() でリモートへ送信（await しない）
```

失敗しても dirty=1 が残り、次回 Push で補完される。

---

## フェーズ8：四択進捗画面

**ファイル:** `lib/src/screens/four_choice_progress_screen.dart`

### 現状
`ensureSyncedForLocalRead()` で待ち、Supabase から `question_learning_states` を取得している。

### 変更後

```
triggerBackgroundSync() を呼ぶ（待たない）
  ↓
local_question_learning_states を SQLite から取得
  ↓
即時表示（学習状態タイルが表示される）
  ↓ 同期完了後
SyncNotifier の done で再読み込み
```

`local_question_learning_states` を `learner_id` でフィルタし、`question_supabase_id` を使って問題と突き合わせる。
`retrievability` と `next_review_at` をローカルから読む形に変更する。

---

## フェーズ9：英語例文進捗画面

**ファイル:** `lib/src/screens/english_example_progress_screen.dart`

### 現状
`ensureSyncedForLocalRead()` で待ち、Supabase から `english_example_learning_states` を取得している。

### 変更後

四択進捗画面と同じパターン。`local_english_example_learning_states` を読む形に変更する（フェーズ1のテーブル追加が前提）。

---

## フェーズ10：Web対応（インメモリキャッシュ）

Web は SQLite が使えないため、プラットフォームを `kIsWeb` で分岐し、インメモリキャッシュで対応する。

### キャッシュクラスの作成

**新規ファイル:** `lib/src/cache/web_data_cache.dart`

```dart
class WebDataCache {
  static final WebDataCache instance = WebDataCache._();
  WebDataCache._();

  final Map<String, _CacheEntry> _cache = {};

  List<Map<String, dynamic>>? get(String key) {
    final entry = _cache[key];
    if (entry == null) return null;
    return entry.data;
  }

  void set(String key, List<Map<String, dynamic>> data) {
    _cache[key] = _CacheEntry(data: data, cachedAt: DateTime.now());
  }

  bool isStale(String key, {Duration maxAge = const Duration(minutes: 10)}) {
    final entry = _cache[key];
    if (entry == null) return true;
    return DateTime.now().difference(entry.cachedAt) > maxAge;
  }

  void clear(String key) => _cache.remove(key);
}

class _CacheEntry {
  final List<Map<String, dynamic>> data;
  final DateTime cachedAt;
  const _CacheEntry({required this.data, required this.cachedAt});
}
```

### 保留キュー（SM-2 書き込みのオフライン対応）

**新規ファイル:** `lib/src/cache/web_pending_queue.dart`

```dart
// オフライン中の解答を保留するキュー
class WebPendingQueue {
  static final WebPendingQueue instance = WebPendingQueue._();
  WebPendingQueue._();

  final List<_PendingLearningState> _queue = [];
  bool get hasItems => _queue.isNotEmpty;

  void enqueue(_PendingLearningState item) => _queue.add(item);

  // connectivity_plus でオンライン復帰を検知して呼ぶ
  Future<void> flush(SupabaseClient client) async {
    if (_queue.isEmpty) return;
    final items = List<_PendingLearningState>.from(_queue);
    _queue.clear();
    for (final item in items) {
      try {
        await item.send(client);
      } catch (_) {
        _queue.add(item); // 失敗したら戻す
      }
    }
  }
}
```

### オンライン復帰検知

`main.dart` または app 起動時に `connectivity_plus` のストリームを購読し、オンライン復帰時に `WebPendingQueue.instance.flush()` を呼ぶ。

```dart
// Web のみ
if (kIsWeb) {
  Connectivity().onConnectivityChanged.listen((result) {
    if (result != ConnectivityResult.none) {
      WebPendingQueue.instance.flush(Supabase.instance.client);
    }
  });
}
```

### 各 Web 画面での使い方

```dart
// 1. キャッシュを即時表示
final cached = WebDataCache.instance.get('subjects');
if (cached != null) setState(() => _subjects = cached);

// 2. バックグラウンドでリモート取得
final fresh = await client.from('subjects').select().order('display_order');
WebDataCache.instance.set('subjects', fresh);
if (mounted) setState(() => _subjects = fresh);
```

---

## 実装順序まとめ

依存関係があるため、以下の順番で実装する。

```
フェーズ1（DBスキーマ）
  → フェーズ2（SyncEngine拡張）
    → フェーズ3（バックグラウンド同期ヘルパー）
      → フェーズ4〜9（各画面：並行実装可能）
        → フェーズ10（Web対応：独立して実装可能）
```

フェーズ4〜9の各画面は互いに依存していないため、並行して作業できる。
ただしフェーズ6・7・9はフェーズ1・2の完了が必須。

---

## 各フェーズの影響範囲と確認ポイント

| フェーズ | 変更ファイル | 確認方法 |
|---|---|---|
| 1 | `local_db.dart` | バージョンアップ後、既存DBが正しくマイグレーションされること |
| 2 | `sync_engine.dart` | 初回Pull後に `local_english_examples` にデータが入ること |
| 3 | 新規: `background_sync.dart` | 同期が完了を待たずに画面が表示されること |
| 4 | `learner_home_screen.dart` | オフラインでも科目一覧が表示されること |
| 5 | `question_solve_screen.dart` | オフラインで問題が表示され、解答が記録されること |
| 6 | `english_example_list_screen.dart` | オフラインで例文一覧が表示されること |
| 7 | `english_example_solve_screen.dart` | オフラインで例文練習ができ、評価が保存されること |
| 8 | `four_choice_progress_screen.dart` | オフラインで進捗タイルが表示されること |
| 9 | `english_example_progress_screen.dart` | オフラインで進捗タイルが表示されること |
| 10 | 新規: `web_data_cache.dart`, `web_pending_queue.dart` | Web でオフライン解答がオンライン復帰後に送信されること |

---

## 変更しない箇所

以下は現状の実装で問題なく、変更不要。

- `SyncEngine.recordQuestionLearningProgress()` — ローカル書き込みは正しく実装済み
- `KnowledgeRepositoryLocal` — すでにローカルDBを正しく読んでいる
- `SubjectRepositoryLocal` — すでにローカルDBを正しく読んでいる
- `SyncEngine` の Pull/Push ロジック全般 — LWW 競合解消を含め正しく実装済み
- 教師側の画面全般 — `ensureSyncedForLocalRead()` のまま（書き込み後は最新を見せる必要があるため）
- `memorization_solve_screen.dart` — データを引数で受け取るため同期不要
