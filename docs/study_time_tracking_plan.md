# 勉強時間記録機能 設計方針

## 概要

問題（四択・テキスト入力）および知識カードを学習している時間を記録する機能。
主にスマホ版での利用を想定する。

---

## 計測対象画面

| 画面 | 対象 | 備考 |
|------|------|------|
| `question_solve_screen.dart` | 問題を解いている時間 | 四択・テキスト入力 |
| `knowledge_detail_screen.dart` | 知識カードを読んでいる時間 | 学習者モードのみ |
| `english_example_solve_screen.dart` | 例文学習の時間 | TTS再生中含む |
| `memorization_solve_screen.dart` | 暗記カード学習の時間 | 将来的に追加可 |

---

## 計測ルール

### 1. 画面が消えている時間はカウントしない

- `AppLifecycleState` を監視し、以下の状態の時はタイマーを**一時停止**する
  - `paused`：アプリがバックグラウンドに移行（ホームボタン等）
  - `inactive`：画面ロック・電話着信等による一時的な非アクティブ化
  - `detached`：アプリが完全に停止
- `resumed` に戻ったタイミングでタイマーを**再開**する

### 2. 音声読み上げ（TTS）中はカウントする

- `flutter_tts` の再生状態コールバックを使って TTS の開始・終了を検知する
- TTS 再生中はアプリが `paused` であっても**例外的にカウントを継続**する
  - ただし、スマホのスリープ中は TTS が実際に停止することがあるため、OS の動作に依存する部分がある（後述）
- TTS が停止（完了・手動停止）した場合は通常のライフサイクルルールに戻る

### 3. 画面遷移・セッション分割

- 対象画面に入った時点でセッション開始
- 対象画面から離れた時点でセッション終了・保存
- 1回の「滞在」を1セッションとして記録する

---

## データ設計

### ローカル DB（SQLite）テーブル

```sql
CREATE TABLE study_sessions (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  session_type TEXT NOT NULL,     -- 'question' | 'knowledge' | 'english_example' | 'memorization'
  content_id   TEXT,              -- 問題ID・カードID（任意）
  subject_id   TEXT,              -- 科目ID（任意）
  started_at   TEXT NOT NULL,     -- ISO8601 UTC
  ended_at     TEXT,              -- ISO8601 UTC（NULL = 記録中）
  duration_sec INTEGER,           -- 計測秒数（ended_at - started_at から休止分を除いた値）
  created_at   TEXT NOT NULL
);
```

### フィールド補足

- `duration_sec`：画面消灯・バックグラウンド時間を除いた**純粋な学習時間**
- `ended_at` が NULL のレコードはアプリ強制終了等による未完了セッション。起動時にクリーンアップする

### Supabase への同期

- ローカルに記録後、既存の sync engine の仕組みに乗せてリモートへ同期する（後フェーズで対応）
- フェーズ1ではローカル保存のみで十分

---

## アーキテクチャ方針

### StudyTimerService（新規サービスクラス）

```
lib/src/services/study_timer_service.dart
```

責務：
- タイマーの開始・一時停止・再開・終了
- `AppLifecycleObserver` の管理
- TTS 状態との連携
- DB への保存

```dart
class StudyTimerService with WidgetsBindingObserver {
  // セッション開始
  void startSession(String sessionType, {String? contentId, String? subjectId});

  // セッション終了（保存）
  Future<void> endSession();

  // TTS 開始通知（TTS中はバックグラウンドでもカウント継続）
  void onTtsStarted();

  // TTS 終了通知
  void onTtsStopped();

  // AppLifecycleState 変化ハンドラ
  @override
  void didChangeAppLifecycleState(AppLifecycleState state);
}
```

### 各画面での利用方法

各対象画面の `initState` / `dispose` で `StudyTimerService` を呼び出す。

```dart
// 例：知識カード詳細画面
@override
void initState() {
  super.initState();
  StudyTimerService.instance.startSession('knowledge', contentId: widget.knowledgeId);
}

@override
void dispose() {
  StudyTimerService.instance.endSession();
  super.dispose();
}
```

TTS を使う画面では `TtsService` 側のコールバックから `StudyTimerService` に通知する。

---

## TTS + スリープの扱いについて

スマホのスリープ（画面オフ）中の TTS 動作は OS・設定によって変わる。

| 状況 | 挙動 |
|------|------|
| iOS：バックグラウンド再生設定あり | TTS が継続する → カウント継続でよい |
| Android：バッテリー最適化が厳しい端末 | TTS が停止することがある |
| アプリが `paused` 状態で TTS 再生中 | `onTtsCompleted` が来たタイミングで TTS 終了とみなす |

**方針**：`flutter_tts` の `completionHandler` / `cancelHandler` をトリガーとして TTS 状態を管理する。TTS 中は一時停止しないが、TTS が止まったら通常ルール（`paused` ならタイマー停止）に戻る。アプリが `paused` になった際に TTS が動いているかを確認し、動いていなければ即座にタイマーを止める。

---

## 表示・集計（将来フェーズ）

- 日別・週別の勉強時間グラフ
- 科目ごとの時間内訳
- 連続学習日数（ストリーク）

フェーズ1では記録のみを実装し、表示は別タスクとする。

---

## 実装フェーズ

### フェーズ1（最小実装）
1. `study_sessions` テーブルをローカル DB に追加
2. `StudyTimerService` を実装
3. `knowledge_detail_screen` と `question_solve_screen` に組み込む
4. `english_example_solve_screen` に TTS 連携込みで組み込む

### フェーズ2
5. `memorization_solve_screen` への対応
6. Supabase sync 対応
7. 集計・表示 UI の実装

---

## 考慮点・注意事項

- **アプリ強制終了への対応**：`started_at` だけ記録されて `ended_at` がないセッションはアプリ起動時に `duration_sec = null` として確定させる（または削除する）
- **画面の重なり**：ダイアログ表示中は `inactive` になることがあるが、短時間なので許容するか、閾値（例：3秒以上の `inactive`）を設けて判断する
- **マルチセッション**：複数の対象画面を同時に開くことは基本的にない想定（シングルスタック）。念のため同時セッションは防ぐ
- **プライバシー**：記録するのは時間・種別・ID のみ。問題の回答内容や知識カードの本文は記録しない
