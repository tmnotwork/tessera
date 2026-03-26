# 英作文エラーハイライト機能 設計方針

## 概要

英作文出題画面（`english_example_composition_screen.dart`）において、学習者が回答を入力したとき、
正解と異なる箇所を赤字で表示する機能を追加する。

---

## 現状の整理

- `english_examples` テーブルに `back_en`（正解の英文）が格納されている
- `english_example_composition_screen.dart` はまだ実装されていない（リストからimportされているが未作成）
- 回答の正誤は `last_answer_correct` として保存される仕組みが `english_example_composition_state_remote.dart` で定義されている
- 現状では「正解 / 不正解」のフラグしか保存されておらず、どこが間違っているかは追跡していない

---

## 難しさの所在

英作文のエラーハイライトが単純でない理由は以下の通り：

1. **複数の正解がある**
   例：`I have been to Tokyo` も `I've been to Tokyo` も正解になりうる。

2. **語順の違い**
   副詞の位置など、語順が多少変わっても意味的に正しい場合がある。

3. **スペルミスの扱い**
   `recieve` → `receive` のような軽微なミスを「完全な誤り」と扱うべきか、「惜しい」と扱うべきか。

4. **文法ミスの説明**
   「どこが間違っているか」だけでなく「なぜ間違っているか」を伝えないと学習効果が低い。

---

## 実装方針：段階的アプローチ

### Phase 1：単語レベルのDiff比較（初期実装）

**アルゴリズム：LCS（最長共通部分列）ベースのWord Diff**

1. ユーザーの回答と `back_en` をそれぞれ単語に分割する
   - 小文字に統一
   - ピリオド・カンマなどの句読点を分離または除去
2. LCS アルゴリズムで両リストの一致単語を求める
3. LCS に含まれない単語を「誤り」として赤色表示

**表示方法（Flutter の RichText / TextSpan を使用）**

- ユーザーの回答を表示する行：
  - LCS に含まれる単語 → 黒文字（または緑文字）
  - LCS に含まれない単語 → 赤文字
- 正解を表示する行（参照用）：
  - ユーザー回答にない単語 → 青文字（不足している箇所）
  - 一致している単語 → 通常色

**例：**
```
あなたの回答：  I have go to school yesterday.
                    ^^      ^^^^^^^^^^^
（赤字：go / yesterday → 正解と一致しない）

正解：          I went to school yesterday.
                  ^^^^
（青字：went → ユーザーが書けなかった単語）
```

**メリット**
- API不要、オフラインで動作
- 実装がシンプル
- レスポンスが速い

**デメリット**
- 同義語・言い換えを区別できない（例：`big` vs `large` は別物扱い）
- 語順が変わると誤検知が増える
- 「なぜ間違いか」の説明ができない

---

### Phase 2：LLMによる評価（拡張実装）

Phase 1 の diff 表示では「どこが違うか」を機械的に示すに留まる。
より深い学習支援のために、Claude API を使ったフィードバックを追加する。

**API呼び出しの内容**

```
システム：英語教師として、学習者の英作文を評価してください。
入力：
  - 日本語のお題（front_ja）
  - 模範解答（back_en）
  - 学習者の回答（user_answer）

出力（JSON形式）：
  - errors: [ { word: "go", reason: "過去形にすべきで went が正しい" }, ... ]
  - overall_correct: true/false
  - comment: "全体として～" （省略可）
```

**実装上の考慮**
- API レスポンスを待つ間はローディング表示
- エラー時はフォールバックとして Phase 1 の diff 表示のみ使用
- API コストを抑えるため、ユーザーが「詳しく見る」ボタンを押したときだけ呼び出す設計も検討

---

## 実装ファイル構成（案）

```
lib/src/
├── utils/
│   └── word_diff.dart            # LCS ベースの word diff ロジック（新規）
├── screens/
│   └── english_example_composition_screen.dart   # 英作文出題画面（新規）
│       ├── 回答入力 TextField
│       ├── 回答後の diff 表示ウィジェット（RichText）
│       └── 正解表示ウィジェット
└── widgets/
    └── diff_text_display.dart    # RichText で diff を表示する共通ウィジェット（新規）
```

---

## `word_diff.dart` の仕様（Phase 1）

```dart
/// 2つの英文を比較し、単語レベルの差分を返す
List<DiffWord> wordDiff(String userAnswer, String correctAnswer);

class DiffWord {
  final String word;
  final DiffStatus status; // matched / added（ユーザー過剰） / missing（ユーザー不足）
}

enum DiffStatus { matched, added, missing }
```

---

## `diff_text_display.dart` の仕様

```dart
/// ユーザーの回答を diff 結果に基づいて色付き表示
/// - matched → 黒
/// - added（余分な単語）→ 赤
Widget buildUserAnswerText(List<DiffWord> diff);

/// 正解を diff 結果に基づいて色付き表示
/// - matched → 黒
/// - missing（ユーザーが書けなかった単語）→ 青
Widget buildCorrectAnswerText(List<DiffWord> diff);
```

---

## 画面フロー（英作文出題画面）

```
1. 日本語のお題（front_ja）を表示
2. 学習者が英文を入力
3. 「回答する」ボタンをタップ
4. ↓ 以下が表示される
   ┌──────────────────────────────────┐
   │ あなたの回答：                      │
   │  I have [go] to school yesterday.   │  ← 赤字：go
   │                                    │
   │ 正解：                             │
   │  I [went] to school yesterday.     │  ← 青字：went
   │                                    │
   │ （Phase 2）詳しいフィードバック：     │
   │  ・go → went（過去形にしてください）  │
   └──────────────────────────────────┘
5. 「正解」「不正解」ボタンで自己採点
6. 結果を composition_state に保存
```

---

## 今後の検討事項

- **大文字・小文字の扱い**：比較時は lowercase に統一、表示は元の入力のまま
- **句読点の扱い**：ピリオドやカンマは比較対象から除外するか別トークンとして扱う
- **部分的な一致の評価**：例えば全10単語中8単語一致なら「惜しい」として質をつける
- **複数の模範解答対応**：将来的に `back_en` の複数パターンを登録できるようにする（現在はDBスキーマが1つのみ）
- **コスト管理**：LLM利用は任意トリガーにして過剰なAPI呼び出しを防ぐ

---

## 実装優先度

| フェーズ | 内容 | 難易度 | 優先度 |
|--------|------|-------|-------|
| Phase 1 | word_diff.dartの実装 | 低 | 高 |
| Phase 1 | diff_text_display.dartの実装 | 低〜中 | 高 |
| Phase 1 | composition_screenへの組み込み | 中 | 高 |
| Phase 2 | Claude API連携（フィードバック生成） | 中〜高 | 中 |
| 将来 | 複数模範解答のDB対応 | 高 | 低 |
