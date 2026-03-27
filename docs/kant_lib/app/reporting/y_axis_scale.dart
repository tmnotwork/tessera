import 'dart:math' as math;

/// fl_chart の縦軸（Y軸）ラベルが「重ならない本数」になるように、
/// データ最大値と描画可能高さから「いい感じの interval / maxY」を計算する。
///
/// - 値は「時間（hours）」前提（ラベルは呼び出し側で HH:MM に変換）
/// - interval は 1/2/5×10^n 系で切り上げ（見やすさ優先）
class YAxisScale {
  final double maxY;
  final double interval;

  const YAxisScale({
    required this.maxY,
    required this.interval,
  });
}

YAxisScale computeHoursYAxisScale({
  required double dataMaxHours,
  required double plotHeightPx,
  required double labelFontSizePx,
  double headroomRatio = 0.15,
  double minHeadroomHours = 0.5,
  double maxHeadroomHours = 2.0,
  int minLabels = 3,
  int maxLabels = 7,
  double extraLabelPaddingPx = 6.0,
}) {
  final safeMaxHours = (dataMaxHours.isFinite && dataMaxHours > 0)
      ? dataMaxHours
      : 1.0;

  final headroom = (safeMaxHours * headroomRatio)
      .clamp(minHeadroomHours, maxHeadroomHours);
  final rawMaxY = (safeMaxHours + headroom).clamp(1.0, double.infinity);

  final safePlotHeightPx = (plotHeightPx.isFinite && plotHeightPx > 0)
      ? plotHeightPx
      : 240.0;

  final safeFontSize = (labelFontSizePx.isFinite && labelFontSizePx > 0)
      ? labelFontSizePx
      : 12.0;

  final labelHeightPx = safeFontSize * 1.25;
  final minSpacingPx = labelHeightPx + extraLabelPaddingPx;

  final allowedLabels = (safePlotHeightPx / minSpacingPx)
      .floor()
      .clamp(minLabels, maxLabels);

  final desiredSteps = math.max(1, allowedLabels - 1);
  final roughStep = rawMaxY / desiredSteps;
  final interval = _niceCeilStep(roughStep);

  final maxYAligned = (rawMaxY / interval).ceil() * interval;

  return YAxisScale(maxY: maxYAligned, interval: interval);
}

double _niceCeilStep(double x) {
  if (!x.isFinite || x <= 0) return 1.0;

  // 1/2/5 × 10^n の “切り上げ”。
  final exp = math.pow(10.0, (math.log(x) / math.ln10).floor()).toDouble();
  final f = x / exp;

  final nf = (f <= 1.0)
      ? 1.0
      : (f <= 2.0)
          ? 2.0
          : (f <= 5.0)
              ? 5.0
              : 10.0;

  return nf * exp;
}

