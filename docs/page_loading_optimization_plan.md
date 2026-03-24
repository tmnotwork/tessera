# 画面読み込み最適化 方針書

作成日: 2026-03-24

---

## 背景・課題

画面を開くたびに毎回読み込みが発生し、待ちが生じている。
原因を分析し、最小コストから順に対策を実施していく。

---

## 現状の問題点

### 1. 毎回フルクエリ

各画面の `initState` で、毎回ゼロからデータを取得している。
前回取得済みのデータが残っていても再利用されない。

**該当箇所（例）:**
- `learner_home_screen.dart` — `initState` で `_fetchSubjects()` を毎回呼び出し
- `knowledge_list_screen.dart` — `initState` で `_load()` を毎回呼び出し
- `four_choice_list_screen.dart` — `initState` で `_load()` を毎回呼び出し

### 2. モバイル/デスクトップの sync-first

画面表示前に `ensureSyncedForLocalRead()` が毎回ネットワーク確認・同期を実行する。
直前に同期済みであっても再度実行される。

**該当箇所:**
- `ensure_synced_for_local_read.dart` — 呼び出し元は各画面の `_load()`

### 3. ページネーションなし

全件を1クエリで取得してから表示する。件数が増えると初期表示が遅くなる。

**該当箇所:**
- `four_choice_list_screen.dart` — `.select()` で全件取得（limit/offset なし）

### 4. リクエスト重複防止なし

同じ画面を短時間で連続して開くと、同じクエリが重複して発行される。

---

## 最適化方針

### レベル1: すぐできる（低コスト・即効性大）

#### 1-1. sync 頻度の制限

`ensureSyncedForLocalRead()` に「直近N秒以内に sync 済みならスキップ」する条件を追加する。

```dart
// 現状
Future<void> ensureSyncedForLocalRead() async {
  if (kIsWeb) return;
  if (!SyncEngine.isInitialized) return;
  await SyncEngine.instance.syncIfOnline();
}

// 改善後（例: 30秒以内はスキップ）
Future<void> ensureSyncedForLocalRead() async {
  if (kIsWeb) return;
  if (!SyncEngine.isInitialized) return;
  final lastSync = SyncMetadataStore.lastSyncAt;
  if (lastSync != null &&
      DateTime.now().difference(lastSync).inSeconds < 30) return;
  await SyncEngine.instance.syncIfOnline();
}
```

**対象ファイル:** `lib/src/sync/ensure_synced_for_local_read.dart`

#### 1-2. in-flight guard（重複リクエスト防止）

各画面の `_load()` に「すでに読み込み中なら return」のガードを追加する。

```dart
Future<void> _load() async {
  if (_isLoading) return;  // ← 追加
  setState(() => _isLoading = true);
  // ...
}
```

**対象ファイル:** 各画面の `_load()` メソッド

---

### レベル2: 中程度の変更（Repository レベルのキャッシュ）

#### 2-1. TTL付きメモリキャッシュ

Repository 層に取得済みデータをキャッシュし、TTL（例: 5分）以内は再取得しない。

```dart
class KnowledgeRepositoryLocal implements KnowledgeRepository {
  List<Knowledge>? _cache;
  DateTime? _cacheAt;
  static const _ttl = Duration(minutes: 5);

  @override
  Future<List<Knowledge>> getBySubject(String subjectId) async {
    if (_cache != null &&
        _cacheAt != null &&
        DateTime.now().difference(_cacheAt!) < _ttl) {
      return _cache!;
    }
    final result = await _fetchFromDb(subjectId);
    _cache = result;
    _cacheAt = DateTime.now();
    return result;
  }

  void invalidate() {
    _cache = null;
    _cacheAt = null;
  }
}
```

**キャッシュ無効化タイミング:**
- データの書き込み・削除時
- 手動リフレッシュ時
- 認証状態変化時

**対象ファイル:** `lib/src/repositories/knowledge_repository.dart`, `subject_repository.dart`

#### 2-2. ChangeNotifier でリスト状態を共有

`AppScope` に `KnowledgeNotifier` / `SubjectNotifier` を追加し、複数画面が同じデータを参照する。
一方の画面が更新したら全体に反映される（再取得不要）。

```dart
class SubjectNotifier extends ChangeNotifier {
  List<Subject> _subjects = [];
  bool _loaded = false;

  List<Subject> get subjects => _subjects;

  Future<void> fetch() async {
    if (_loaded) return;
    _subjects = await _repository.getAll();
    _loaded = true;
    notifyListeners();
  }

  void invalidate() {
    _loaded = false;
    notifyListeners();
  }
}
```

**対象ファイル:** `lib/src/app_scope.dart`（新規 Notifier を追加）

---

### レベル3: 根本的な改善（将来対応）

#### 3-1. ページネーション

Supabase の `.range()` / `.limit()` を使い、初期表示は先頭N件のみ取得する。
スクロールに応じて追加取得（無限スクロール）。

```dart
// 例: 最初の20件だけ取得
final rows = await client
    .from('questions')
    .select(...)
    .order('created_at', ascending: false)
    .range(0, 19);  // ← 追加
```

**対象ファイル:** `four_choice_list_screen.dart`, `knowledge_list_screen.dart` など

#### 3-2. バックグラウンドプリフェッチ

次に開く可能性が高い画面のデータを、現在の画面表示中にバックグラウンドで取得しておく。

#### 3-3. Riverpod 導入（大規模改修）

キャッシュ・非同期管理・状態共有を Riverpod に一元化する。
移行コストは大きいが、長期的なメンテナンス性が大きく向上する。

---

## 実施優先順位

```
優先度1（今すぐ）
├── sync 頻度の制限（1-1）
└── in-flight guard（1-2）

優先度2（次のサイクル）
├── Repository TTL キャッシュ（2-1）
└── ChangeNotifier 共有（2-2）

優先度3（中長期）
├── ページネーション（3-1）
├── バックグラウンドプリフェッチ（3-2）
└── Riverpod 導入（3-3）
```

---

## 期待効果

| 施策 | 改善される待ち | 実装コスト |
|---|---|---|
| sync 頻度制限 | モバイル/デスクトップの画面遷移全般 | 小 |
| in-flight guard | 連続タップ・連続遷移時の重複クエリ | 小 |
| TTL キャッシュ | 同一データへの繰り返しアクセス | 中 |
| ChangeNotifier 共有 | タブ切替・画面戻りの再取得 | 中 |
| ページネーション | 大量データ時の初期表示 | 中 |
