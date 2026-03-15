# Supabase 本番設定手順（確認メール・パスワードリセット）

確認メールのリンクを開いたときに「localhost で接続が拒否されました」とならないようにするため、**Supabase の URL 設定**が必要です。  
**Supabase の公式サイト（https://supabase.com）を Site URL にすることはしないでください。** あなたのアプリのユーザーを第三者サイトに飛ばすことになり、適切ではありません。

---

## 開発中に確認メールを動かす：2つの選択肢

### 選択肢 A：メール確認を省略する（設定不要・すぐログイン）

確認メールのリンクを使わず、登録後すぐログインできるようにする。

1. **Supabase ダッシュボード** を開く: https://supabase.com/dashboard  
2. 対象の **プロジェクト** を選択する  
3. 左メニュー **Authentication** → **Providers** → **Email** を開く  
4. **「Confirm email」** を **OFF** にする  
5. **Save** をクリックする  

これ以降、新規登録したユーザーはメール確認なしでログインできます。Site URL の設定は不要です。本番リリース前に Confirm email を ON に戻し、下記「本番リリース時」の設定を行うこと。

---

### 選択肢 B：開発中も確認メールのリンクを動かす（あなたが公開する URL が必要）

確認メールのリンクの行き先は **あなたが公開している HTTPS の URL** でなければなりません。次のどちらかで URL を用意する。

#### B-1. GitHub Pages で確認完了ページを公開する

1. このリポジトリの **`static/email-confirmed.html`** を、GitHub リポジトリの **`docs` フォルダ** に **`index.html`** という名前でコピーする（中身は同じでよい）。  
2. リポジトリの **Settings** → **Pages** を開く。  
3. **Source** を **Deploy from a branch** にし、**Branch** を `main`（またはデフォルトブランチ）、**Folder** を **`/docs`** にして **Save** する。  
4. 数分後、**https://（あなたのGitHubユーザー名）.github.io/（リポジトリ名）/** でページが開く。この URL を控える（末尾スラッシュなしでよい。例: `https://tmnor.github.io/learning_platform/`）。  
5. **Supabase ダッシュボード** → 対象プロジェクト → **Authentication** → **URL Configuration** を開く。  
6. **Site URL** に、手順 4 で控えた URL を入力する。  
7. **Redirect URLs** を開き、**Add URL** で **Site URL とまったく同じ値**を追加する。  
8. **Save** をクリックする。  
9. アプリで **「確認メールを再送」** を押し、**新しく届いたメール** のリンクから開く（古いメールのリンクは使わない）。

#### B-2. Vercel / Netlify で確認完了ページを公開する

1. **`static/email-confirmed.html`** を **`index.html`** として、Vercel または Netlify にデプロイする（プロジェクトのルートにこの1ファイルだけでも可）。  
2. 発行された URL（例: `https://（プロジェクト名）.vercel.app`）を控える。  
3. **Supabase ダッシュボード** → 対象プロジェクト → **Authentication** → **URL Configuration** を開く。  
4. **Site URL** に、手順 2 の URL を入力する。  
5. **Redirect URLs** に **Add URL** で同じ URL を追加する。  
6. **Save** をクリックする。  
7. アプリで「確認メールを再送」を押し、新しいメールのリンクから開く。

---

## 本番リリース時

本番でアプリを公開するドメインが決まっている場合。

1. **本番のルート URL** を決める。  
   - Tessera を Web で公開する場合: そのアプリの URL（例: `https://tessera.example.com`）。  
   - Web を公開せずモバイル/デスクトップのみの場合: 確認完了用に1つ URL を用意し、`static/email-confirmed.html` をその URL で公開する。  
2. **`static/email-confirmed.html`** を、その本番ドメインでアクセスできるように配置する（ルートまたは `/email-confirmed.html` など）。  
3. **Supabase ダッシュボード** → 対象プロジェクト → **Authentication** → **URL Configuration** を開く。  
4. **Site URL** に本番のルート URL（スラッシュ末尾なし）を入力する。  
5. **Redirect URLs** に **Add URL** で **Site URL とまったく同じ値**を追加する。  
6. **Save** をクリックする。  
7. 「確認メールを再送」から新しいリンクで動作確認する。

---

## まとめ

| 状況 | やること |
|------|----------|
| 開発・とにかくすぐログインしたい | 選択肢 A: Confirm email を OFF にする。Site URL は触らない。 |
| 開発・確認メールの流れを試したい | 選択肢 B: `static/email-confirmed.html` を GitHub Pages / Vercel / Netlify で公開し、その URL を Site URL と Redirect URLs に設定する。 |
| 本番 | 本番ドメインで `static/email-confirmed.html` を公開し、その本番ルート URL を Site URL と Redirect URLs に設定する。 |

**Site URL に `https://supabase.com` を設定しないこと。** 必ずあなたが管理・公開している URL を使う。
