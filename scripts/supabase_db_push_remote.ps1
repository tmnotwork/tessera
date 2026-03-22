# リモートの Supabase Postgres に、supabase/migrations 配下の未適用マイグレーションを適用する。
#
# 事前準備（初回のみ）:
#   1) supabase login
#   2) ダッシュボードの Project Settings → Database で DB パスワードを確認
#   3) リポジトリのルート（learning_platform）で実行:
#        supabase link --project-ref <参照ID> -p "<DBパスワード>"
#      参照IDは URL https://xxxx.supabase.co の xxxx（例: wnufzrehvhcwclnwxwim）
#
# このスクリプトの実行（リポジトリルートから）:
#   powershell -ExecutionPolicy Bypass -File scripts/supabase_db_push_remote.ps1
#
# ドライラン（適用せず内容だけ確認）:
#   supabase db push --linked --dry-run

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

Write-Host ">>> supabase db push --linked（リモートへマイグレーション適用）" -ForegroundColor Cyan
supabase db push --linked
