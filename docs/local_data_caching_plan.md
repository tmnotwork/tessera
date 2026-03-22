# ローカルデータキャッシュ設計方針

## 背景と課題

### 現状の問題

学習画面を開くと、毎回データの読み込み待ちが発生する。

主な原因は2つある。

1. **同期待ち**: `ensureSyncedForLocalRead()` を呼び出し、同期が完了してからデータ取得を開始している。
2. **常にリモート取得**: モバイル・デスクトップでも `Supabase.instance.client.from(...)` でリモートにアクセスしており、ローカルSQLiteが活用されていない。

具体的には以下の2画面が代表例。

- `learner_home_screen.dart`: `_fetchSubjects()` で同期待ち → Supabaseからサブジェクト取得
- `question_solve_screen.dart`: `_loadQuestion()` で同期待ち → Supabaseから問題取得

---

## 設計方針：ローカルファースト + バックグラウンド同期

### 基本考え方

> **読み取り・書き込みともにローカルを正とし、ネットワークはバックグラウンドで使う**

「Stale-While-Revalidate（SWR）」の考え方をベースに、SM-2学習状態も含むすべてのデータをオフラインで完結させる。

### フェーズ定義

```
フェーズ1: ローカルキャッシュから即時表示（0ms〜）
  ↓
フェーズ2: バックグラウンドで最新データを取得（非同期、オンライン時のみ）
  ↓
フェーズ3: 差分があればUIを更新（取得完了後）
```

ユーザーは最初からコンテンツを見ることができ、オフラインでも学習が止まらない。

---

## データ種別と対応方針

### コンテンツデータ（問題・知識・例文）

読み取り専用（学習者は編集しない）。多少古くてもよい。SWRパターンをそのまま適用する。

### SM-2学習状態データ（`question_learning_states` / `english_example_learning_states`）

学習者が書き込む唯一のデータ。オフラインでも解答を受け付け、オンライン復帰時に同期する。

**設計原則: 書き込みはローカルが常に先。リモートは後から追いつく。**

```
[解答操作]
  ↓
ローカルに保存（dirty=1）← ここで完結。解答は必ず記録される。
  ↓ バックグラウンドで（オンライン時）
Supabaseへ Push
  ↓
dirty=0、synced_at を記録
```

**競合解消**: `updated_at` による LWW（Last-Write-Wins）。`dirty=1` のローカルレコードは必ずリモートより新しい（ローカルで操作した直後のため）。

---

## キャッシュ層の設計

### プラットフォーム別の対応

| プラットフォーム | 読み取りキャッシュ | 書き込みキャッシュ | バックグラウンド同期 |
|---|---|---|---|
| モバイル / デスクトップ | ローカルSQLite（既存） | ローカルSQLite + dirty フラグ（既存） | SyncEngine（既存） |
| Web | インメモリキャッシュ（新規） | インメモリキャッシュ + 保留キュー（新規） | Supabase直接クエリ（既存）+ オンライン復帰時フラッシュ |

### モバイル・デスクトップ

すでに `LocalDatabase`（SQLite）と `SyncEngine` が存在し、SM-2状態の書き込みもローカルに保存される仕組みが整っている。

**現在の問題点**: 画面がSQLiteを読まずにSupabaseへ直接アクセスしている。

変更前:
```
同期完了待ち → Supabaseから取得 → 表示
```

変更後:
```
SQLiteから即時取得 → 表示（ここまでが瞬時、オフラインでも動く）
           ↓ 並行してバックグラウンドで（オンライン時のみ）
    SyncEngine.sync() を起動
           ↓ 同期完了後
    SQLiteを再度読み、差分があればUIを更新
```

**SM-2データの読み取りも同様**: `question_learning_states` をSupabaseから取得している箇所を、SQLiteから読む形に変える。`dirty=1` のレコードは最新のローカル状態を示すため、そのまま信頼して表示してよい。

### Web

Webは `sqflite` 非対応のため、シンプルなインメモリキャッシュを導入する。

```dart
// 例: シングルトンのキャッシュマネージャ
class WebDataCache {
  static final WebDataCache _instance = WebDataCache._();
  static WebDataCache get instance => _instance;

  final Map<String, _CacheEntry> _cache = {};

  T? get<T>(String key) => ...;
  void set<T>(String key, T value) { ... }
  bool isStale(String key, Duration maxAge) { ... }
}

class _CacheEntry {
  final dynamic data;
  final DateTime cachedAt;
}
```

**Webのオフライン書き込み（SM-2）**: 解答操作時にネットワークが切れていた場合、インメモリの「保留キュー」に積み、オンライン復帰を `connectivity_plus` で検知してフラッシュする。

```dart
// 保留キューの概念
class WebPendingQueue {
  final List<_PendingWrite> _queue = [];

  void enqueue(_PendingWrite write) { ... }

  // connectivity_plus でオンライン復帰を検知して呼ぶ
  Future<void> flush(SupabaseClient client) async { ... }
}
```

---

## データフローの詳細

### 読み取りパターン（コンテンツ・SM-2状態 共通）

```dart
Future<void> _loadData() async {
  // --- フェーズ1: ローカルキャッシュから即時表示 ---
  final cached = await _loadFromLocalCache();
  if (cached != null && cached.isNotEmpty) {
    setState(() {
      _data = cached;
      _loading = false; // すぐにローディングを終わらせる
    });
  }

  // --- フェーズ2: バックグラウンドで最新データを取得（オンライン時のみ） ---
  try {
    final fresh = await _fetchFromRemoteOrSync();
    await _saveToLocalCache(fresh);

    if (mounted && _isDataDifferent(_data, fresh)) {
      setState(() => _data = fresh);
    }
  } catch (e) {
    // ローカルデータが表示されているのでエラーはサイレント処理
    // キャッシュがない場合のみエラーを表示
    if ((_data == null || _data!.isEmpty) && mounted) {
      setState(() => _error = e.toString());
    }
  }
}
```

### 書き込みパターン（SM-2状態のみ）

```dart
Future<void> _recordAnswer(bool isCorrect) async {
  // ステップ1: ローカルに即時保存（オフラインでも必ず記録される）
  await _saveToLocalCache(newState); // モバイル: SQLite dirty=1 / Web: メモリキュー

  // UIはすぐに更新（ネットワーク待ちなし）
  setState(() => _learningState = newState);

  // ステップ2: バックグラウンドでリモートへ送信（失敗しても記録は残る）
  _syncToRemoteInBackground(newState);
}

void _syncToRemoteInBackground(LearningState state) {
  unawaited(() async {
    try {
      await _upsertToSupabase(state);
      await _markLocalSynced(state.localId);
    } catch (_) {
      // dirty=1 のまま残るため、次回の SyncEngine.sync() で再送される
    }
  }());
}
```

### 重要な原則

1. **ローカルに保存できた時点で解答は「記録完了」とみなす**。ネットワーク送信の成否でUIをブロックしない。
2. **バックグラウンド同期の失敗はサイレント処理**。`dirty=1` が残るため次回同期で補完される。
3. **差分チェックを入れる** ことで不要な再レンダリングを避ける。
4. **`mounted` チェックを必ず行う** ことで画面離脱後の `setState` を防ぐ。

---

## 優先的に対応すべき画面

### 優先度：高

| 画面 | ファイル | 対応内容 |
|---|---|---|
| 学習ホーム | `learner_home_screen.dart` | サブジェクト取得をSQLite読み取り＋バックグラウンド同期に変更 |
| 四択問題 | `question_solve_screen.dart` | 問題・SM-2状態の読み書きをローカルファーストに変更 |
| 例文練習 | `english_example_solve_screen.dart` | `_statesCache` 既存実装を活かしつつローカルDBへ永続化 |

### 優先度：中

| 画面 | ファイル | 対応内容 |
|---|---|---|
| 四択進捗 | `four_choice_progress_screen.dart` | `question_learning_states` をSQLiteから集計 |
| 例文進捗 | `english_example_progress_screen.dart` | 同上（例文版） |
| 学習状況メニュー | `learner_learning_status_menu_screen.dart` | サブジェクト統計をローカル集計に変更 |

---

## SM-2データの整合性保証

### 競合が起きる状況

複数デバイスから同じ学習者が解答した場合（例：スマホとタブレット）。

### 解消ルール

`updated_at` によるLWW（Last-Write-Wins）。新しい方が正しい。

```
デバイスA: 09:00 に解答 → dirty=1, updated_at=09:00
デバイスB: 09:05 に解答 → dirty=1, updated_at=09:05

Push時: 09:05 の方が新しいため、B の状態が Supabase に上書きされる
Pull時: Supabase から 09:05 の状態が A にも反映される
```

この方針はすでに `SyncEngine` に実装済み。追加の変更は不要。

### `reviewed_count` の扱い

現在 `EnglishExampleLearningStateRemote.upsertState()` は `reviewed_count` をリモートの値ベースで加算している（二重カウント防止）。ローカルファースト化後は**ローカルの値を正とする**。Push時にローカルの `reviewed_count` をそのまま送り、リモートを上書きする。

---

## 実装ステップ（推奨順序）

### Step 1: バックグラウンド同期トリガーの共通化

`ensureSyncedForLocalRead()` をそのまま置き換えず、「ローカル読み取り用」のヘルパーとして新規作成する。

```dart
// lib/src/sync/read_local_with_background_sync.dart

/// ローカルDBを読める状態であることを前提とし、
/// バックグラウンドで同期を走らせる。同期完了を待たない。
void triggerBackgroundSync() {
  if (SyncEngine.isInitialized) {
    unawaited(SyncEngine.instance.syncIfOnline());
  }
}
```

### Step 2: `learner_home_screen.dart` のサブジェクト取得を改修

最初に開く画面であり、効果が最大。`LocalTable.subjects` から読み、バックグラウンドで同期。

### Step 3: `question_solve_screen.dart` の問題・SM-2状態をローカルファーストに

問題本体は `LocalTable.questions` / `LocalTable.questionChoices` から読む。
SM-2状態は `LocalTable.questionLearningStates` から読む。
解答保存後の `QuestionLearningStateRemote.upsertState()` 呼び出しはバックグラウンドに変更。

### Step 4: Webプラットフォーム向けキャッシュ層の実装

`kIsWeb` で分岐し、インメモリキャッシュ + 保留キューを導入。
`connectivity_plus` の `onConnectivityChanged` でオンライン復帰を検知し、保留キューをフラッシュ。

### Step 5: 進捗・統計画面の改修

閲覧のみで書き込みがないため、SWRが最も安全に適用できる。

---

## 注意事項・リスク

### 初回起動・ログイン直後

キャッシュが存在しない初回はフォールバックとして通常のローディングを表示する。SWRは「キャッシュあり」を前提とするため、初回はオンライン必須として割り切る。

### Webでのページリロード

インメモリキャッシュはリロードでクリアされる。保留キューも同様に失われる。Webはオフライン中にタブを閉じると未送信の解答が消える点を許容するか、`localStorage` への永続化を追加検討する（実装コストと相談）。

### UIのちらつき

フェーズ1（キャッシュ表示）とフェーズ3（更新後）の間にデータが増減すると画面がガタつく場合がある。コンテンツの追加・削除は教師側で発生し、学習中は稀なため、初期対応はアニメーションなしで許容する。

### バックグラウンド同期中のインジケーター

`ForceSyncIconButton` が既に AppBar に実装済み。バックグラウンド同期が走っていることをユーザーに示すためにそのまま活用する。

---

## まとめ

| 項目 | 変更前 | 変更後 |
|---|---|---|
| 表示速度 | 同期完了まで待機 | ローカルキャッシュを即時表示 |
| オフライン閲覧 | 不可（エラー） | 可（ローカルデータを表示） |
| オフライン解答 | 不可（SM-2状態が保存されない） | 可（ローカルに保存、復帰後に同期） |
| データアクセス | 毎回リモート | ローカルファースト、リモートはバックグラウンド |
| ネットワーク影響 | UX直結 | バックグラウンドに隠れる |

SM-2データも含め「ローカルを正」とすることで、オフライン中でも完全に学習を継続できる。
