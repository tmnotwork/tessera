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
フェーズ1: ローカルキャッシュから即時表示（ネットワーク往復を待たず、体感上一瞬）
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

教師側で問題を削除・非公開にした場合、Pull 同期でローカルへ論理削除や非表示フラグが反映される前提とする。反映までの間は古いキャッシュが残り得るため、表示時に「存在しない／利用不可」の扱いを決めておく（同期後にリストから消える、エラー表示に切り替える、など）。初期対応では既存の同期スキーマに合わせ、必要なら tombstone や `deleted_at` の伝播を `SyncEngine` 側で補強する。

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

**競合解消**: `updated_at` による LWW（Last-Write-Wins）。`dirty=1` のローカルレコードは、当該デバイス上では直近の解答を表すため、**そのデバイスから見た最新**として扱う。

**LWW の限界**: 端末時計のずれや同一秒内の操作では「新しい方」の判定が曖昧になり得る。可能ならサーバー側の更新時刻やリビジョンに寄せる余地はあるが、現状は `SyncEngine` の実装に従い、極端なずれは運用上稀として許容する。

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

**Webのオフライン書き込み（SM-2）**: 解答操作時に送信できなかった場合、インメモリの「保留キュー」に積む。`connectivity_plus` で**接続の復帰**を検知したらフラッシュを試みる。

**接続オンラインと API 成功の区別**: Wi‑Fi に繋がっていても Supabase が 5xx やタイムアウトになることがある。フラッシュは **upsert が成功するまでキューに残す**（失敗時は再試行。指数バックオフや最大リトライ回数を設けると安全）。「オンラインになった」だけでキューを捨てない。

```dart
// 保留キューの概念
class WebPendingQueue {
  final List<_PendingWrite> _queue = [];

  void enqueue(_PendingWrite write) { ... }

  // 接続復帰時・定期タイマーなどから呼ぶ。成功するまで dequeue しない
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
    // キャッシュありで長期オフライン／API失敗が続く場合、
    // 「最新ではない」ことを示すかはプロダクト判断（例: ForceSyncIconButton の状態、軽いバナー）
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
5. **読み取りのフェーズ2が続けて失敗する場合**、ローカル表示は維持しつつ、「最終同期から時間が経っている」などをユーザーに示すかは任意。既存の `ForceSyncIconButton` で同期の手動トリガーを提供する方針と相性がよい。

---

## 優先的に対応すべき画面

### 優先度：高

| 画面 | ファイル | 対応内容 |
|---|---|---|
| 学習ホーム | `learner_home_screen.dart` | サブジェクト取得をSQLite読み取り＋バックグラウンド同期に変更 |
| 四択問題 | `question_solve_screen.dart` | 問題・SM-2状態の読み書きをローカルファーストに変更 |
| 例文練習 | `english_example_solve_screen.dart` | `_statesCache` を活かしつつモバイルでは SQLite へ永続化。四択と同様に `english_example_learning_states` が `LocalTable`／`SyncEngine` の dirty パスで扱えるか実装前に確認し、足りなければ四択側と揃える |

### 優先度：中

| 画面 | ファイル | 対応内容 |
|---|---|---|
| 四択進捗 | `four_choice_progress_screen.dart` | モバイル・デスクトップ: `question_learning_states` を SQLite から集計。**Web**: SQLite がないため、`kIsWeb` でインメモリキャッシュの集計か Supabase 直接取得に分岐（本ドキュメントの Web 節とセットで設計する） |
| 例文進捗 | `english_example_progress_screen.dart` | 同上（例文版。状態テーブル名のみ異なる） |
| 学習状況メニュー | `learner_learning_status_menu_screen.dart` | モバイル・デスクトップはローカル集計。**Web** は同上の分岐 |

---

## SM-2データの整合性保証

### 競合が起きる状況

複数デバイスから同じ学習者が解答した場合（例：スマホとタブレット）。

### 解消ルール

`updated_at` による LWW（Last-Write-Wins）。新しい方が正しい。端末時計のずれや同一秒内の衝突は、データ種別の「競合解消」で述べた限界と同様に扱う。

```
デバイスA: 09:00 に解答 → dirty=1, updated_at=09:00
デバイスB: 09:05 に解答 → dirty=1, updated_at=09:05

Push時: 09:05 の方が新しいため、B の状態が Supabase に上書きされる
Pull時: Supabase から 09:05 の状態が A にも反映される
```

この方針はすでに `SyncEngine` に実装済み。追加の変更は不要。

### `reviewed_count` の扱い

現在 `EnglishExampleLearningStateRemote.upsertState()` は `reviewed_count` をリモートの値ベースで加算している（二重カウント防止）。ローカルファースト化後は**ローカルの値を正とする**。Push時にローカルの `reviewed_count` をそのまま送り、リモートを上書きする。

`SyncEngine` 内でも `reviewed_count` を扱っているため、変更時は **Remote の upsert と Engine の Push／Pull の両方**でローカル正の前提が崩れていないか確認する。

---

## 実装ステップ（推奨順序）

### Step 1: バックグラウンド同期トリガーの共通化

`ensureSyncedForLocalRead()` を**廃止せず**残す。用途を分ける。

- **ローカルに中身が既にある画面**: `triggerBackgroundSync()` のみ（同期完了を待たない）。
- **初回起動・ログイン直後・対象テーブルが空**など、ローカル読みで表示できない場合: 従来どおり **`await ensureSyncedForLocalRead()` を一度走らせる**、または初回セットアップ専用フローでフル同期を完了させてから以降はバックグラウンドのみ、のどちらかに実装で統一する。

```dart
// lib/src/sync/read_local_with_background_sync.dart（想定パス）

/// ローカルに表示可能なデータがある前提で、バックグラウンド同期だけ起動する。
void triggerBackgroundSync() {
  if (SyncEngine.isInitialized) {
    unawaited(SyncEngine.instance.syncIfOnline());
  }
}
```

空の SQLite に対して `triggerBackgroundSync()` だけでは、ユーザーが待たずに中身が増えるまで表示が空のままになり得る点に注意する。

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

閲覧のみで書き込みがないため、SWRが最も安全に適用できる。モバイル・デスクトップは SQLite 集計に寄せ、**Web は Step 4 のインメモリキャッシュまたは Supabase 直読みと整合させる**（優先度：中の表を参照）。

---

## 注意事項・リスク

### 初回起動・ログイン直後

キャッシュが存在しない初回は、**ローカルが空のまま即時表示できない**。方針を次のいずれかに実装で統一する。

1. **ブロッキング同期**: その画面の初回だけ `await ensureSyncedForLocalRead()`（または同等のフル同期）を行い、続けて SQLite 読み取りに移る。
2. **専用オンボーディング**: ログイン直後の一度だけフル同期を完了させ、以降の画面は常に `triggerBackgroundSync()` のみ。

いずれも「2回目以降はローカルファースト」が成立するようにする。SWR は「キャッシュあり」を前提とするため、**初回だけオンライン必須に割り切る**のは変わらない。

### Webでのページリロード

インメモリキャッシュはリロードでクリアされる。保留キューも同様に失われる。Webはオフライン中にタブを閉じると未送信の解答が消える点を許容するか、`localStorage` への永続化を追加検討する（実装コストと相談）。

### UIのちらつき

フェーズ1（キャッシュ表示）とフェーズ3（更新後）の間にデータが増減すると画面がガタつく場合がある。コンテンツの追加・削除は教師側で発生し、学習中は稀なため、初期対応はアニメーションなしで許容する。

### バックグラウンド同期中のインジケーター

`ForceSyncIconButton` が既に AppBar に実装済み。バックグラウンド同期が走っていることをユーザーに示すためにそのまま活用する。フェーズ2が長く失敗し続ける場合の「古いキャッシュ表示」の補助としても利用できる（重要な原則 5 と対応）。

### Supabase への影響（誤ってDBを消すリスク）

本設計の実装は **「読み取りをローカル優先にし、同期は既存の `SyncEngine` と同じ経路でバックグラウンド起動する」** ことが中心である。次の理由から、**テーブル丸ごとの削除や、条件なしの一括 DELETE のような事故は、設計どおり実装すれば起きない**。

1. **`SyncEngine` の Pull**  
   リモートから **select してローカルへマージするだけ**であり、Supabase 側の行を `delete` しない。

2. **`SyncEngine` の Push（通常の dirty 行）**  
   教材・問題・学習状態などは **`insert` / `upsert` / `update`** で送る。`question_learning_states` も upsert 系の経路であり、**行単位の物理 DELETE を同期で投げない**。

3. **Push の「削除」に相当する処理**  
   ローカルで `deleted=1` かつ `dirty=1` にマークされた行についてのみ、リモートへ **`deleted_at` をセットする update（ソフトデリート）** が走る。これは教師側のオフライン削除フロー用であり、学習者が四択・例文を解く処理とは別経路である。

4. **本変更で新たにやること**  
   `triggerBackgroundSync()` は内部で既存の `syncIfOnline()` を呼ぶだけなので、**同期の「リモートに対して何をするか」は現状と同じ**。画面側は SQLite 読み取りと `setState` のタイミングが変わるだけで、**新規コードで `client.from(...).delete()` を増やさない限り、Supabase のデータが誤って消える経路は増えない**。

実装時のチェックとして、学習者向けのローカルファースト改修では **Supabase に対する `.delete()` や危険な一括更新を追加しない**ことをコードレビューで確認するとよい。

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
