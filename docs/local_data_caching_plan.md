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

## 設計方針：Stale-While-Revalidate（SWR）パターン

### 基本考え方

> **まずキャッシュを即時表示し、バックグラウンドで最新データを取得して差分があればUIを更新する**

これは「Stale-While-Revalidate（古いデータを見せながら再検証する）」と呼ばれるパターンで、Webフロントエンドでは標準的なアプローチ。

### フェーズ定義

```
フェーズ1: キャッシュから即時表示（0ms〜）
  ↓
フェーズ2: バックグラウンドで最新データを取得（非同期）
  ↓
フェーズ3: 差分があればUIを更新（取得完了後）
```

ユーザーは最初からコンテンツを見ることができ、更新があれば自然にUIが書き換わる。

---

## キャッシュ層の設計

### プラットフォーム別の対応

| プラットフォーム | フェーズ1（即時）のキャッシュ | フェーズ2（バックグラウンド）の更新元 |
|---|---|---|
| モバイル / デスクトップ | ローカルSQLite（既存） | Supabase（SyncEngine経由） |
| Web | インメモリキャッシュ（新規） | Supabase（直接クエリ） |

### モバイル・デスクトップ

すでに `LocalDatabase`（SQLite）が存在するため、**まずSQLiteから読む**だけでよい。

現在の流れ:
```
同期完了待ち → Supabaseから取得 → 表示
```

変更後の流れ:
```
SQLiteから即時取得 → 表示（ここまでが瞬時）
           ↓ 並行してバックグラウンドで
    SyncEngineで最新データを取得
           ↓ 同期完了後
    SQLiteを再度読み、差分があればUIを更新
```

### Web

現状はキャッシュがなくリモートのみ。シンプルなインメモリキャッシュを導入する。

```dart
// 例: シングルトンのキャッシュマネージャ
class WebDataCache {
  static final WebDataCache _instance = WebDataCache._();
  static WebDataCache get instance => _instance;

  final Map<String, _CacheEntry> _cache = {};

  T? get<T>(String key) { ... }
  void set<T>(String key, T value) { ... }
  bool isStale(String key, Duration maxAge) { ... }
}

class _CacheEntry {
  final dynamic data;
  final DateTime cachedAt;
}
```

---

## データフローの詳細

### 標準的な実装パターン

各画面で以下のパターンを採用する。

```dart
Future<void> _loadData() async {
  // --- フェーズ1: キャッシュから即時表示 ---
  final cached = await _loadFromLocalCache();
  if (cached != null && cached.isNotEmpty) {
    setState(() {
      _data = cached;
      _loading = false; // すぐにローディングを終わらせる
    });
  }

  // --- フェーズ2: バックグラウンドで最新データを取得 ---
  try {
    final fresh = await _fetchFromRemote(); // 非同期・待たない
    await _saveToLocalCache(fresh);

    if (mounted && _isDataDifferent(_data, fresh)) {
      setState(() => _data = fresh);
    }
  } catch (e) {
    // キャッシュが表示されているのでエラーは軽微に扱う
    // キャッシュがなかった場合のみエラーを表示
    if (_data.isEmpty && mounted) {
      setState(() => _error = e.toString());
    }
  }
}
```

### 重要な原則

1. **最初のキャッシュがなければ通常のローディングを表示** する（UXの一貫性）
2. **バックグラウンド取得失敗はサイレントに処理** する（既にデータが見えている）
3. **差分チェックを入れる** ことで不要な再レンダリングを避ける
4. **`mounted` チェックを必ず行う** ことで画面離脱後の setState を防ぐ

---

## 優先的に対応すべき画面

### 優先度：高

| 画面 | ファイル | 理由 |
|---|---|---|
| 学習ホーム | `learner_home_screen.dart` | 最初に開く画面。ここが遅いと全体的な印象が悪い |
| 四択問題 | `question_solve_screen.dart` | 問題1問ごとに読み込みが走る |
| 例文練習 | `english_example_solve_screen.dart` | 同上。ただし `_statesCache` は既に実装済み |

### 優先度：中

| 画面 | ファイル | 理由 |
|---|---|---|
| 四択進捗 | `four_choice_progress_screen.dart` | 閲覧頻度が高い |
| 例文進捗 | `english_example_progress_screen.dart` | 同上 |
| 学習状況メニュー | `learner_learning_status_menu_screen.dart` | サブジェクト単位の統計 |

---

## 学習状態データの特別扱い

SM-2アルゴリズムで管理している学習状態（`question_learning_states` など）は、**学習直後に正確な値が必要**なため、通常コンテンツとは異なる扱いをする。

- **問題コンテンツ（questions, choices）**: SWRパターンを適用。多少古くても問題なし。
- **学習状態（learning_states）**: 解答後は必ずリモートへ即時保存し、次回表示時にローカルの最新値を優先する。ローカルに保存した値が常に最新であれば、キャッシュとして安全に使える。

`dirty` フラグがついているレコードはローカルの方が新しい状態を示すため、リモートより優先する。

---

## 実装ステップ（推奨順序）

### Step 1: ローカルキャッシュ読み取りの共通化

`ensureSyncedForLocalRead()` の代替として、「キャッシュ読み取り用」のヘルパーを作成する。

```dart
// lib/src/sync/local_cache_reader.dart
/// キャッシュが存在すれば即時返す。バックグラウンドで同期を走らせる。
Future<void> triggerBackgroundSync() async {
  unawaited(SyncEngine.instance.sync());
}
```

### Step 2: `learner_home_screen.dart` のサブジェクト取得を改修

最もユーザーが最初に見る画面であり、効果が大きい。

### Step 3: `question_solve_screen.dart` の問題取得を改修

問題ごとの読み込みを高速化する。

### Step 4: Webプラットフォーム向けインメモリキャッシュの実装

Webは `kIsWeb` で分岐し、キャッシュ層を追加する。

### Step 5: 進捗・統計画面の改修

閲覧のみで書き込みがないため、SWRが最も安全に適用できる。

---

## 注意事項・リスク

### データ整合性

- 学習状態は「ローカルの `dirty=1` レコードが最新」という前提を守ること。
- 解答の記録は SWR の対象外とし、必ず同期処理を挟む。

### UI/UX

- フェーズ1（キャッシュ表示）とフェーズ3（更新後）の間に画面がガタつく場合がある。データが増減したり順番が変わったりする場合は、`AnimatedList` や差分アニメーションの導入を検討する。
- バックグラウンド同期中であることをユーザーに伝える軽微なインジケーター（AppBarのアイコンなど）は既に `ForceSyncIconButton` として実装済みなので活用する。

### 初回起動・ログイン直後

- キャッシュが存在しない初回はフォールバックとして通常のローディングを表示する。SWRは「キャッシュあり」を前提とするため、初回のUXは別途考慮する。

### Webでのキャッシュ有効期限

- インメモリキャッシュはページリロードでクリアされる。セッション内であれば基本的に有効期限を長めに設定してよい（例：10分）。
- ただし、他のデバイス・タブからの変更は即時反映されない点を許容する。

---

## まとめ

| 変更前 | 変更後 |
|---|---|
| 同期完了まで待機 → 表示 | キャッシュを即時表示 → バックグラウンドで同期 → 差分を更新 |
| 毎回リモートへアクセス | ローカルファースト、リモートはバックグラウンド |
| ネットワーク遅延がそのままUXに影響 | ネットワーク遅延はバックグラウンドに隠れる |

このパターンを採用することで、学習画面のローディング時間をほぼゼロにしつつ、データの鮮度も担保できる。
