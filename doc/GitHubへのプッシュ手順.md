# GitHub に保存する手順

リポジトリはすでに Git 管理されており、初回コミット済みです。あとは GitHub にリポジトリを作成してプッシュするだけです。

## 1. GitHub で新しいリポジトリを作る

1. [GitHub](https://github.com) にログインする
2. 右上の **+** → **New repository**
3. **Repository name** を入力（例: `tessera`）
4. **Public** を選択（Private でも可）
5. **「Add a README file」などはチェックしない**（ローカルに既にコードがあるため）
6. **Create repository** をクリック

## 2. リモートを追加してプッシュ

GitHub でリポジトリを作成すると、表示されるコマンドのうち **「…or push an existing repository from the command line」** を使います。

プロジェクトフォルダでターミナルを開き、次を実行します（`YOUR_USERNAME` は自分の GitHub ユーザー名に置き換えてください）:

```powershell
cd c:\Users\tmnor\OneDrive\Dev\learning_platform

git remote add origin https://github.com/YOUR_USERNAME/tessera.git
git branch -M main
git push -u origin main
```

- **HTTPS** の場合は初回プッシュ時に GitHub のユーザー名とパスワード（または Personal Access Token）を聞かれます。
- **SSH** を使う場合は `git remote add origin git@github.com:YOUR_USERNAME/tessera.git` にします。

## 3. プッシュ後の確認

GitHub のリポジトリページを開くと、コードが反映されています。  
今後は変更をコミットしたあと、`git push` で反映できます。

## 注意

- **`.env`** と **`.cursor/mcp.json`** は .gitignore で除外しているため、GitHub には上がりません（秘密情報を守るため）。
- 他の PC でクローンした場合は、`.env.example` をコピーして `.env` を作り、Supabase の URL とキーを設定してください。
