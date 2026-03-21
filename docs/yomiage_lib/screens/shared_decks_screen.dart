// ignore_for_file: use_build_context_synchronously, avoid_print, library_private_types_in_public_api

import 'package:flutter/material.dart';
import 'package:yomiage/services/firebase_service.dart';
import 'package:intl/intl.dart';
import 'package:yomiage/services/hive_service.dart';
import 'package:yomiage/models/deck.dart';

class SharedDecksScreen extends StatefulWidget {
  const SharedDecksScreen({Key? key}) : super(key: key);

  @override
  _SharedDecksScreenState createState() => _SharedDecksScreenState();
}

class _SharedDecksScreenState extends State<SharedDecksScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _isLoading = false;
  List<Map<String, dynamic>> _publicDecks = [];
  List<Map<String, dynamic>> _mySharedDecks = [];
  String? _errorMessage;

  // 検索用の変数を追加
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  bool _isSearching = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadDecks();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  // 検索クエリでデッキをフィルタリングするメソッド
  List<Map<String, dynamic>> _filterDecks(List<Map<String, dynamic>> decks) {
    if (_searchQuery.isEmpty) {
      return decks;
    }

    final query = _searchQuery.toLowerCase();
    return decks.where((deck) {
      final deckName = (deck['deckName'] ?? '').toLowerCase();
      final description = (deck['description'] ?? '').toLowerCase();

      return deckName.contains(query) || description.contains(query);
    }).toList();
  }

  // 検索を開始する
  void _startSearch() {
    setState(() {
      _isSearching = true;
    });
  }

  // 検索をキャンセルする
  void _stopSearch() {
    setState(() {
      _isSearching = false;
      _searchQuery = '';
      _searchController.clear();
    });
  }

  // 検索クエリを更新する
  void _updateSearchQuery(String query) {
    setState(() {
      _searchQuery = query;
    });
  }

  Future<void> _loadDecks() async {
    if (_isLoading) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // 公開デッキの取得
      final publicDecks = await FirebaseService.getSharedDecks();

      // 自分の共有デッキの取得
      final myDecks = await FirebaseService.getMySharedDecks();

      setState(() {
        _publicDecks = publicDecks;
        _mySharedDecks = myDecks;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'デッキの読み込みに失敗しました: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _downloadDeck(String deckId, String deckName) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      print('デッキのダウンロードを開始: ID=$deckId, 名前=$deckName');

      // ダウンロード前の既存デッキ数を確認
      final deckBox = HiveService.getDeckBox();
      final cardBox = HiveService.getCardBox();
      final beforeDeckCount = deckBox.length;

      print('ダウンロード前のデッキ数: $beforeDeckCount');

      // ダウンロード実行
      await FirebaseService.downloadSharedDeck(deckId);

      // ダウンロード後のデッキ数を確認
      final afterDeckCount = deckBox.length;
      print('ダウンロード後のデッキ数: $afterDeckCount');

      // ダウンロードしたデッキを探す
      Deck? downloadedDeck;
      try {
        downloadedDeck = deckBox.values.firstWhere(
          (deck) =>
              deck.deckName == deckName ||
              deck.deckName.startsWith('$deckName ('),
        );
      } catch (e) {
        print('ダウンロードしたデッキの検索エラー: $e');
        downloadedDeck = null;
      }

      if (downloadedDeck == null) {
        print('警告: ダウンロードしたデッキが見つかりません');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                Text('デッキ「$deckName」をダウンロードしましたが、デッキが見つかりません。アプリを再起動してください。'),
            backgroundColor: Colors.orange,
            duration: const Duration(seconds: 10),
          ),
        );
      } else {
        // ダウンロードしたデッキのカード数を確認
        final deckCards = cardBox.values
            .where((card) => card.deckName == downloadedDeck!.deckName)
            .toList();
        print(
            'ダウンロードしたデッキ「${downloadedDeck.deckName}」のカード数: ${deckCards.length}');

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'デッキ「${downloadedDeck.deckName}」を${deckCards.length}枚のカードとともにダウンロードしました'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 5),
          ),
        );
      }

      setState(() {
        _isLoading = false;
      });
    } catch (e, stackTrace) {
      print('デッキのダウンロードに失敗: $e');
      print('スタックトレース: $stackTrace');

      // エラーメッセージの詳細化
      String errorMessage = 'デッキのダウンロードに失敗しました: $e';
      String detailMessage = '再度お試しいただくか、別のデッキをお試しください。';

      if (e.toString().contains('ユーザーがログインしていません')) {
        errorMessage = 'ログインが必要です';
        detailMessage = 'デッキをダウンロードするには、ログインしてください。';
      } else if (e.toString().contains('共有デッキが見つかりません')) {
        errorMessage = 'デッキが見つかりません';
        detailMessage = 'このデッキは削除されたか、利用できなくなった可能性があります。';
      } else if (e.toString().contains('permission-denied')) {
        errorMessage = 'アクセス権限エラー';
        detailMessage = '共有デッキへのアクセス権限がありません。管理者にお問い合わせください。';
      }

      setState(() {
        _errorMessage = errorMessage;
        _isLoading = false;
      });

      // エラーダイアログを表示
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('ダウンロードエラー'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(errorMessage),
              const SizedBox(height: 16),
              Text(detailMessage),
              const SizedBox(height: 16),
              const Text('詳細情報（開発者向け）:'),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  e.toString(),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('閉じる'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _shareDeck(BuildContext context) async {
    // ログイン確認
    if (FirebaseService.getUserId() == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('共有するにはログインしてください')),
      );
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // ローカルのデッキ一覧を取得
      final deckBox = HiveService.getDeckBox();
      final localDecks = deckBox.values.where((d) => !d.isDeleted).toList();

      print('ローカルデッキ数: ${localDecks.length}');

      if (localDecks.isEmpty) {
        setState(() {
          _isLoading = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('共有できるデッキがありません')),
        );
        return;
      }

      // Firebaseからデッキ一覧を取得
      final cloudDecks = await FirebaseService.getDecks();
      print('クラウドデッキ数: ${cloudDecks.length}');

      // 両方のデッキ名を表示（デバッグ用）
      final localDeckNames = localDecks.map((d) => d.deckName).toList();
      final cloudDeckNames = cloudDecks.map((d) => d.deckName).toList();
      print('ローカルデッキ名: $localDeckNames');
      print('クラウドデッキ名: $cloudDeckNames');

      setState(() {
        _isLoading = false;
      });

      // 共有設定ダイアログを表示
      bool useEmergencyMode = false; // 緊急モード機能は廃止のためUIから非表示、デフォルトは無効

      // 共有設定ダイアログを表示
      final result = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (context) {
          return StatefulBuilder(
            builder: (context, setState) {
              return AlertDialog(
                title: const Text('共有するデッキを選択'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // ※ 緊急モードスイッチを削除しました
                    // デッキリスト
                    Expanded(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: localDecks.length,
                        itemBuilder: (context, index) {
                          final deck = localDecks[index];
                          return ListTile(
                            title: Text(deck.deckName),
                            onTap: () {
                              Navigator.of(context).pop({
                                'deck': deck,
                                'emergencyMode': useEmergencyMode,
                              });
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('キャンセル'),
                  ),
                ],
              );
            },
          );
        },
      );

      // ダイアログがキャンセルされた場合
      if (result == null) return;

      final selectedDeck = result['deck'];
      final emergencyMode = result['emergencyMode'];

      // 既に共有済みか確認し、上書きする場合は確認ダイアログ
      final alreadyShared =
          await FirebaseService.hasSharedDeck(selectedDeck.deckName);
      if (alreadyShared) {
        final overwrite = await showDialog<bool>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: const Text('上書き確認'),
              content: const Text('このデッキはすでに共有済みです。\n共有内容を上書きしますか？'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('キャンセル'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('上書きする'),
                ),
              ],
            );
          },
        );

        if (overwrite != true) {
          return; // ユーザーがキャンセルした場合
        }
      }

      setState(() {
        _isLoading = true;
      });

      try {
        print('共有開始: デッキ名=${selectedDeck.deckName}, 緊急モード=$emergencyMode');

        // カード数を確認
        final cardBox = HiveService.getCardBox();
        final cards = cardBox.values
            .where((card) => card.deckName == selectedDeck.deckName)
            .toList();
        print('ローカルカード数: ${cards.length}');

        if (cards.isEmpty) {
          throw Exception('デッキ「${selectedDeck.deckName}」にはカードがありません');
        }

        // カードの内容を確認（デバッグ用）
        if (cards.isNotEmpty) {
          final firstCard = cards.first;
          print(
              '最初のカード情報: question=${firstCard.question}, answer=${firstCard.answer}, explanation=${firstCard.explanation}');

          // カードデータの検証
          bool hasInvalidData = false;
          String invalidReason = '';

          for (int i = 0; i < cards.length; i++) {
            final card = cards[i];
            if (card.question.isEmpty) {
              hasInvalidData = true;
              invalidReason = 'カード #${i + 1} の問題文が空です';
              break;
            }
            if (card.answer.isEmpty) {
              hasInvalidData = true;
              invalidReason = 'カード #${i + 1} の回答が空です';
              break;
            }
          }

          if (hasInvalidData) {
            throw Exception('無効なカードデータ: $invalidReason');
          }
        }

        // 共有処理を実行
        final sharedId = await FirebaseService.shareDeck(
          selectedDeck.deckName,
          emergencyMode: emergencyMode,
        );
        print('共有完了: ID=$sharedId');

        // 共有後にリストを更新
        await _loadDecks();

        setState(() {
          _isLoading = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'デッキ「${selectedDeck.deckName}」を共有しました${emergencyMode ? "（緊急モード）" : ""}')),
        );
      } catch (e, stackTrace) {
        print('共有エラー: $e');
        print('スタックトレース: $stackTrace');

        // エラーメッセージの詳細化
        String errorMessage = 'デッキの共有に失敗しました: $e';
        String detailMessage = e.toString();

        if (e.toString().contains('Null check operator')) {
          errorMessage = 'データエラー: カードデータに無効な値が含まれています。\n'
              'カードの内容を確認してください。';
          detailMessage = 'カードデータにnull値が含まれています。問題文、回答、説明文を確認してください。\n'
              '解決方法: 緊急モードをオンにして再試行してください。';
        } else if (e.toString().contains('permission-denied')) {
          errorMessage = 'アクセス権限エラー: Firebaseの設定を確認してください。';
          detailMessage =
              'Firebaseのセキュリティルールで、共有デッキコレクションへのアクセスが許可されていない可能性があります。';
        } else if (e.toString().contains('network')) {
          errorMessage = 'ネットワークエラー: インターネット接続を確認してください。';
          detailMessage = 'インターネット接続が不安定か、Firebaseサーバーに接続できません。';
        } else if (e.toString().contains('無効なカードデータ')) {
          errorMessage = e.toString();
          detailMessage = 'カードデータを修正してから再度お試しください。\n'
              '解決方法: 緊急モードをオンにして再試行してください。';
        }

        setState(() {
          _errorMessage = errorMessage;
          _isLoading = false;
        });

        // エラーダイアログを表示
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('共有エラー'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(errorMessage),
                const SizedBox(height: 16),
                const Text('対処方法:'),
                Text(detailMessage),
                const SizedBox(height: 16),
                const Text('詳細情報（開発者向け）:'),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.grey[200],
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    e.toString(),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('閉じる'),
              ),
            ],
          ),
        );
      }
    } catch (e, stackTrace) {
      print('デッキ一覧取得エラー: $e');
      print('スタックトレース: $stackTrace');

      setState(() {
        _errorMessage = 'デッキの読み込みに失敗しました: $e';
        _isLoading = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('デッキの読み込みに失敗しました: $e'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 10),
        ),
      );
    }
  }

  Future<void> _deleteSharedDeck(String deckId, String deckName) async {
    // 確認ダイアログを表示
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('共有デッキの削除'),
          content: Text(
              '共有デッキ「$deckName」を削除しますか？\n\n※この操作は取り消せません。公開を停止し、他のユーザーがダウンロードできなくなります。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('キャンセル'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: TextButton.styleFrom(
                foregroundColor: Colors.red,
              ),
              child: const Text('削除する'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await FirebaseService.deleteSharedDeck(deckId);
      print('デッキを削除しました: ID=$deckId, 名前=$deckName');

      // 削除後にリストを更新
      await _loadDecks();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('共有デッキ「$deckName」を削除しました'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e, stackTrace) {
      print('共有デッキの削除に失敗: $e');
      print('スタックトレース: $stackTrace');

      setState(() {
        _errorMessage = '共有デッキの削除に失敗しました: $e';
        _isLoading = false;
      });

      // エラーメッセージを表示
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('共有デッキの削除に失敗しました: $e'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 10),
        ),
      );
    }
  }

  Widget _buildDeckCard(Map<String, dynamic> deck, bool isMyDeck) {
    final dateFormat = DateFormat('yyyy/MM/dd HH:mm');
    final createdAt = deck['createdAt'] != null
        ? dateFormat.format(deck['createdAt'])
        : '日時不明';

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    deck['deckName'],
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (isMyDeck)
                  IconButton(
                    icon: const Icon(Icons.delete, color: Colors.red),
                    tooltip: 'このデッキの共有を削除',
                    onPressed: () =>
                        _deleteSharedDeck(deck['id'], deck['deckName']),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (deck['description'] != null &&
                deck['description'].toString().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: Text(
                  deck['description'].toString(),
                  style: const TextStyle(fontSize: 14),
                ),
              ),
            Text('カード数: ${deck['cardCount']}枚'),
            Text('共有者: ${deck['createdBy']}'),
            Text('作成日時: $createdAt'),
            Text('ダウンロード数: ${deck['downloadCount']}回'),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (!isMyDeck)
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () =>
                          _downloadDeck(deck['id'], deck['deckName']),
                      child: const Text('ダウンロード'),
                    ),
                  ),
                if (isMyDeck)
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () =>
                          _deleteSharedDeck(deck['id'], deck['deckName']),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                      ),
                      child: const Text('共有を削除'),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _isSearching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'デッキ名や説明を検索...',
                  border: InputBorder.none,
                  hintStyle: TextStyle(color: Colors.white70),
                ),
                style: const TextStyle(color: Colors.white),
                onChanged: _updateSearchQuery,
              )
            : const Text('共有デッキ'),
        actions: [
          // 検索ボタン
          IconButton(
            icon: Icon(_isSearching ? Icons.close : Icons.search),
            tooltip: _isSearching ? '検索をキャンセル' : '検索',
            onPressed: _isSearching ? _stopSearch : _startSearch,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '公開デッキ'),
            Tab(text: '自分の共有'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          _errorMessage!,
                          style: const TextStyle(color: Colors.red),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: _loadDecks,
                          child: const Text('再試行'),
                        ),
                      ],
                    ),
                  ),
                )
              : TabBarView(
                  controller: _tabController,
                  children: [
                    // 公開デッキタブ
                    RefreshIndicator(
                      onRefresh: _loadDecks,
                      child: _filterDecks(_publicDecks).isEmpty
                          ? Center(
                              child: _searchQuery.isNotEmpty
                                  ? const Text('検索結果に一致するデッキはありません')
                                  : const Text('公開されているデッキはありません'))
                          : ListView.builder(
                              itemCount: _filterDecks(_publicDecks).length,
                              itemBuilder: (context, index) {
                                return _buildDeckCard(
                                    _filterDecks(_publicDecks)[index], false);
                              },
                            ),
                    ),

                    // 自分の共有タブ
                    RefreshIndicator(
                      onRefresh: _loadDecks,
                      child: _filterDecks(_mySharedDecks).isEmpty
                          ? Center(
                              child: _searchQuery.isNotEmpty
                                  ? const Text('検索結果に一致するデッキはありません')
                                  : const Text('共有しているデッキはありません'))
                          : ListView.builder(
                              itemCount: _filterDecks(_mySharedDecks).length,
                              itemBuilder: (context, index) {
                                return _buildDeckCard(
                                    _filterDecks(_mySharedDecks)[index], true);
                              },
                            ),
                    ),
                  ],
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _shareDeck(context),
        child: const Icon(Icons.share),
      ),
    );
  }
}
