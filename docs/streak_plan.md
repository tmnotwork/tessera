# 連続学習ストリーク機能 設計方針

## 概要

Duolingo のような「連続して学習した日数（ストリーク）」を表示・祝う仕組み。
学習モチベーションの維持を目的とし、毎日アプリを開いて何らかの学習を行ったことをカウントする。

---

## ストリーク定義

| 項目 | 定義 |
|------|------|
| 「学習した日」の条件 | ローカル時刻でその日付に `study_sessions` レコードが 1 件以上存在する |
| 最小学習単位 | セッション種別・時間は問わない（duration_sec = 0 のレコードでも可） |
| 日付の起算 | ローカルタイムゾーンのカレンダー日付（UTC ではなく端末時刻） |
| ストリーク継続条件 | 今日 **または** 昨日に学習していれば継続とみなす（昨日まで継続中の場合、今日未学習でもストリークは保持） |
| ストリーク失効条件 | 昨日も今日も学習なし（2日以上の空白）でリセット |

---

## データ設計方針

### 新規 DB テーブル不要

既存の `study_sessions` テーブルから以下のクエリで算出するため、マイグレーション不要。

```sql
-- 学習済み日付一覧（ローカル日付文字列で取得）
SELECT DISTINCT date(started_at, 'localtime') AS study_date
FROM study_sessions
WHERE learner_id = ?
ORDER BY study_date DESC;
```

この結果リストを使って、連続日数をアプリ側で計算する。

### SharedPreferences によるキャッシュ

毎回 DB を全件スキャンしないよう、計算結果をローカルにキャッシュする。

| キー | 型 | 内容 |
|------|----|------|
| `streak_current` | int | 現在の連続日数 |
| `streak_longest` | int | 最長連続日数 |
| `streak_last_computed_date` | String (yyyy-MM-dd) | キャッシュ計算日 |
| `streak_last_celebrated` | int | 最後にお祝いしたストリーク数 |

キャッシュは「今日の日付 = 計算日」であれば再利用し、日付が変わったら再計算する。

---

## アーキテクチャ

### 新規ファイル

| ファイル | 役割 |
|----------|------|
| `lib/src/repositories/streak_repository.dart` | ストリーク算出・キャッシュ管理 |
| `lib/src/widgets/streak_badge.dart` | ホーム画面上部の炎アイコン＋日数バッジ |
| `lib/src/widgets/streak_celebration_dialog.dart` | マイルストーン達成時のお祝いダイアログ |

### `StreakRepository` の責務

```dart
class StreakRepository {
  /// ストリーク情報を返す（キャッシュ優先、必要に応じて再計算）
  Future<StreakInfo> getStreakInfo(String learnerId) async { ... }

  /// 強制再計算（同期後に呼ぶ）
  Future<StreakInfo> recompute(String learnerId) async { ... }
}

class StreakInfo {
  final int current;   // 現在の連続日数
  final int longest;   // 最長連続日数
  final bool isNewRecord; // 今日初めて記録更新したか
}
```

ストリーク算出ロジック（Dart 側）:
1. DB から降順に学習済み日付リストを取得（`study_sessions` を local_db から検索）
2. 今日 or 昨日を起点として、日付が 1 日ずつ連続しているかチェック
3. 途切れたところでカウントを停止

---

## UI 設計

### ホーム画面（`learner_home_screen.dart`）

ヘッダー部分またはカード上部に **炎アイコン + 連続日数** を常時表示。

```
🔥 12  （例：12 日連続）
```

- ストリークが 0 の場合は非表示（または灰色で「今日から始めよう」）
- タップすると詳細画面または簡易ポップアップを表示（将来拡張）

### お祝いダイアログ（`streak_celebration_dialog.dart`）

以下のマイルストーンに初めて到達したとき、ホーム画面ロード後に自動表示。

| マイルストーン | メッセージ例 |
|--------------|------------|
| 3 日 | 「3日連続！いいスタートです 🎉」 |
| 7 日 | 「1週間連続！習慣になってきた 🔥」 |
| 14 日 | 「2週間連続！素晴らしい継続力 ✨」 |
| 30 日 | 「30日連続！本物の習慣です 🏆」 |
| 60 日 | 「60日連続！圧倒的な努力 💪」 |
| 100 日 | 「100日連続！伝説のストリーク 🌟」 |

同じマイルストーンで二度表示しないよう `streak_last_celebrated` で管理。

ダイアログデザイン：
- `AlertDialog` をベースにした軽量実装
- 閉じるボタン（「続ける」）のみ
- アニメーションは最小限（`AnimatedOpacity` 程度）

---

## 呼び出しフロー

```
LearnerHomeScreen._loadData()
  ↓
SyncEngine.syncIfOnline() // 既存の同期処理
  ↓
StreakRepository.recompute(learnerId)
  ↓
setState(streakInfo = result)
  ↓（初回ロード or 画面復帰時）
if (isMilestone && !alreadyCelebrated)
  → showDialog(StreakCelebrationDialog)
```

---

## 実装ステップ

| ステップ | 内容 | 優先度 |
|---------|------|--------|
| 1 | `StreakRepository` を実装（DB クエリ + キャッシュ） | 高 |
| 2 | `StreakBadge` ウィジェットを実装し、ホーム画面に組み込む | 高 |
| 3 | `StreakCelebrationDialog` を実装し、マイルストーン時に表示 | 中 |
| 4 | セッション記録後（`StudyTimerService` のセッション終了時）にもストリーク再計算を走らせる | 低（最初はホーム復帰時の計算のみで十分） |

---

## 考慮事項・制約

### オフライン動作
- `study_sessions` は完全にローカル SQLite で管理されているため、オフラインでも正しくストリークを計算できる。

### マルチデバイス
- 複数端末で使用している場合、Supabase に push 済みのセッションは双方向同期されるため、同期後に再計算すれば整合性は保たれる。
- ただし、同期タイミングにより端末間でストリーク表示にズレが生じる可能性あり（許容範囲とする）。

### タイムゾーン
- ローカル時刻基準のため、日付変更のタイミングはユーザーの端末時計に依存する。
- `date(started_at, 'localtime')` を SQLite クエリで使用することで対応。

### 既存テーブルへの変更なし
- `study_sessions` スキーマはそのまま利用する。
- 追加マイグレーション不要。

---

## 将来的な拡張案（実装対象外）

- ストリーク詳細画面（カレンダー形式で学習日を可視化）
- ストリーク凍結アイテム（1日休んでもリセットしない）
- 週間ストリーク（連続した週）
- 教師からの「今週の皆勤者」一覧表示
