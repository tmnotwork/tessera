# Android ビルド手順

## OneDrive 内でビルドする場合

プロジェクトが **OneDrive** 内にあるため、ビルド出力は **LOCALAPPDATA**（OneDrive 外）に出すようにしています。  
**`flutter clean` は使わず、`flutter build apk` だけ実行してください。**

### 既に build をジャンクションにしている場合

ジャンクションのままだと Gradle 8 で「not a regular file」エラーになります。**一度ジャンクションを削除**してからビルドしてください。

1. OneDrive を一時停止、Cursor を終了
2. プロジェクト直下で:
   ```powershell
   cmd /c rmdir build
   ```
   （ジャンクションは `rmdir` で削除。中身は LOCALAPPDATA に残ります）
3. `flutter build apk` を実行

### 通常のビルド（推奨: スクリプトを使う）

Gradle は APK を **LOCALAPPDATA** に出力するため、Flutter が APK を見つけられるよう **`build\app\outputs\flutter-apk` をジャンクション**にする必要があります。  
**`build_android.ps1`** がジャンクション作成とビルドをまとめて行います。

```powershell
.\build_android.ps1
```

手動でビルドする場合は、**初回だけ**以下を実行してから `flutter build apk` してください。

```powershell
New-Item -ItemType Directory -Force -Path "$env:LOCALAPPDATA\tessera_android_build\app\outputs\flutter-apk"
New-Item -ItemType Directory -Force -Path "build\app\outputs"
cmd /c mklink /J "build\app\outputs\flutter-apk" "$env:LOCALAPPDATA\tessera_android_build\app\outputs\flutter-apk"
flutter build apk --dart-define=dart.library.io.force_staggered_ipv6_lookup=true
```

**Android で Supabase 接続時に SocketException が出る場合**は、次のように **IPv6 対策の dart-define を付けて**ビルドしてください。

```powershell
flutter build apk --dart-define=dart.library.io.force_staggered_ipv6_lookup=true
```

`build_android.ps1` は上記オプション付きでビルドします。

- **APK の場所**: `build\app\outputs\flutter-apk\app-release.apk`（ビルド後に Gradle がここへコピーします）
- 実体のビルド出力: `%LOCALAPPDATA%\tessera_android_build\`

### その他の対処

- プロジェクトを OneDrive 外（例: `C:\Dev\learning_platform`）に置けば、通常どおり `flutter clean` と `flutter build apk` が使えます。
