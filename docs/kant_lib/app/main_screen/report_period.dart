enum ReportPeriod {
  daily('日', '日次レポート'),
  weekly('週', '週次レポート'),
  monthly('月', '月次レポート'),
  yearly('年', '年次レポート'),
  custom('カスタム', 'カスタム期間');

  const ReportPeriod(this.label, this.fullName);
  final String label;
  final String fullName;
}