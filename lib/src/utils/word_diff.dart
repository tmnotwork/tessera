// LCS ベースの単語レベル diff（英作文答え合わせ用）

/// 比較・表示用のトークン（正規化キーと元の表記）
class DiffToken {
  const DiffToken({required this.raw, required this.norm});

  final String raw;
  final String norm;
}

enum DiffStatus { matched, added, missing }

class DiffWord {
  const DiffWord({required this.word, required this.status});

  final String word;
  final DiffStatus status;
}

/// 英文を単語トークンに分割（英単語とアポストロフィ内包のみ。句読点は比較から除外）
List<DiffToken> tokenizeEnglish(String text) {
  final s = text.trim();
  if (s.isEmpty) return [];
  final re = RegExp(r"[\w']+", unicode: true);
  final out = <DiffToken>[];
  for (final m in re.allMatches(s)) {
    final raw = m.group(0)!;
    final norm = raw.trim().toLowerCase();
    if (norm.isEmpty) continue;
    out.add(DiffToken(raw: raw, norm: norm));
  }
  return out;
}

/// 2 つの英文を比較し、ユーザー側・正解側それぞれの単語列に status を付与する。
({List<DiffWord> userWords, List<DiffWord> correctWords}) wordDiffLines(
  String userLine,
  String correctLine,
) {
  final ua = tokenizeEnglish(userLine);
  final ca = tokenizeEnglish(correctLine);
  if (ua.isEmpty && ca.isEmpty) {
    return (userWords: const [], correctWords: const []);
  }

  final un = ua.map((e) => e.norm).toList();
  final cn = ca.map((e) => e.norm).toList();
  final lcs = _lcsIndices(un, cn);

  final userStatus = List<DiffStatus>.filled(ua.length, DiffStatus.added);
  final corrStatus = List<DiffStatus>.filled(ca.length, DiffStatus.missing);

  for (final p in lcs) {
    userStatus[p.$1] = DiffStatus.matched;
    corrStatus[p.$2] = DiffStatus.matched;
  }

  final userWords = <DiffWord>[
    for (var i = 0; i < ua.length; i++)
      DiffWord(word: ua[i].raw, status: userStatus[i]),
  ];
  final correctWords = <DiffWord>[
    for (var i = 0; i < ca.length; i++)
      DiffWord(word: ca[i].raw, status: corrStatus[i]),
  ];
  return (userWords: userWords, correctWords: correctWords);
}

/// LCS の一致ペア (i in user, j in correct)
List<(int, int)> _lcsIndices(List<String> a, List<String> b) {
  final n = a.length;
  final m = b.length;
  if (n == 0 || m == 0) return [];

  final dp = List.generate(
    n + 1,
    (_) => List<int>.filled(m + 1, 0),
  );
  for (var i = 1; i <= n; i++) {
    for (var j = 1; j <= m; j++) {
      if (a[i - 1] == b[j - 1]) {
        dp[i][j] = dp[i - 1][j - 1] + 1;
      } else {
        dp[i][j] = dp[i - 1][j] > dp[i][j - 1] ? dp[i - 1][j] : dp[i][j - 1];
      }
    }
  }

  final pairs = <(int, int)>[];
  var i = n;
  var j = m;
  while (i > 0 && j > 0) {
    if (a[i - 1] == b[j - 1]) {
      pairs.add((i - 1, j - 1));
      i--;
      j--;
    } else if (dp[i - 1][j] >= dp[i][j - 1]) {
      i--;
    } else {
      j--;
    }
  }
  return pairs.reversed.toList();
}
