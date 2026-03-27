import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

/// デバイス情報サービス
class DeviceInfoService {
  static const String _deviceIdKey = 'device_id';
  static const String _deviceTypeKey = 'device_type';
  static const String _deviceNameKey = 'device_name';

  static String? _cachedDeviceId;
  static String? _cachedDeviceType;
  static String? _cachedDeviceName;

  /// デバイス固有IDを取得（初回は生成・保存）
  static Future<String> getDeviceId() async {
    if (_cachedDeviceId != null) {
      return _cachedDeviceId!;
    }

    final box = await Hive.openBox('device_info');

    // 既存のデバイスIDがあるかチェック
    String? deviceId = box.get(_deviceIdKey);

    // デバイスIDが存在しない場合は新しく生成
    if (deviceId == null) {
      deviceId = _generateDeviceId();
      await box.put(_deviceIdKey, deviceId);
    }

    _cachedDeviceId = deviceId;
    return deviceId;
  }

  /// デバイスタイプを取得
  static Future<String> getDeviceType() async {
    if (_cachedDeviceType != null) {
      return _cachedDeviceType!;
    }

    final box = await Hive.openBox('device_info');

    String? deviceType = box.get(_deviceTypeKey);

    // デバイスタイプが存在しない場合はデフォルト値を設定
    if (deviceType == null) {
      deviceType = 'Unknown';
      await box.put(_deviceTypeKey, deviceType);
    }

    _cachedDeviceType = deviceType;
    return deviceType;
  }

  /// デバイス名を取得
  static Future<String> getDeviceName() async {
    if (_cachedDeviceName != null) {
      return _cachedDeviceName!;
    }

    final box = await Hive.openBox('device_info');

    String? deviceName = box.get(_deviceNameKey);

    // デバイス名が存在しない場合はデフォルト値を設定
    if (deviceName == null) {
      deviceName = 'Unknown Device';
      await box.put(_deviceNameKey, deviceName);
    }

    _cachedDeviceName = deviceName;
    return deviceName;
  }

  /// デバイス情報の完全セットを取得
  static Future<DeviceInfo> getDeviceInfo() async {
    final deviceId = await getDeviceId();
    final deviceType = await getDeviceType();
    final deviceName = await getDeviceName();

    // Web対応：Platform.operatingSystemの代わりにkIsWebとdefaultTargetPlatformを使用
    String platformName;
    if (kIsWeb) {
      platformName = 'web';
    } else {
      try {
        // Platform.operatingSystemの代わりにPlatform.isXXXを使用
        if (Platform.isAndroid) {
          platformName = 'android';
        } else if (Platform.isIOS) {
          platformName = 'ios';
        } else if (Platform.isWindows) {
          platformName = 'windows';
        } else if (Platform.isMacOS) {
          platformName = 'macos';
        } else if (Platform.isLinux) {
          platformName = 'linux';
        } else {
          platformName = 'unknown';
        }
      } catch (e) {
        // プラットフォーム判定に失敗した場合はdeviceTypeを使用
        platformName = deviceType;
      }
    }

    return DeviceInfo(
      id: deviceId,
      type: deviceType,
      name: deviceName,
      platform: platformName,
      createdAt: DateTime.now(),
    );
  }

  /// デバイスIDを再生成（デバッグ用）
  static Future<String> regenerateDeviceId() async {
    final box = await Hive.openBox('device_info');
    final newDeviceId = _generateDeviceId();

    await box.put(_deviceIdKey, newDeviceId);
    _cachedDeviceId = newDeviceId;

    return newDeviceId;
  }

  /// 一意なデバイスIDを生成
  static String _generateDeviceId() {
    final random = Random();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final randomPart = random.nextInt(999999).toString().padLeft(6, '0');

    return 'device_${timestamp}_$randomPart';
  }

  /// キャッシュをクリア
  static void clearCache() {
    _cachedDeviceId = null;
    _cachedDeviceType = null;
    _cachedDeviceName = null;
  }

  /// サービス初期化
  static Future<void> initialize() async {
    try {
      // デバイス情報を事前に取得してキャッシュ
      await getDeviceId();
      await getDeviceType();
      await getDeviceName();
    } catch (e) {
      // 初期化エラーでもサービスを継続させる
    }
  }
}

/// デバイス情報クラス
class DeviceInfo {
  final String id;
  final String type;
  final String name;
  final String platform;
  final DateTime createdAt;

  DeviceInfo({
    required this.id,
    required this.type,
    required this.name,
    required this.platform,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type,
      'name': name,
      'platform': platform,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  @override
  String toString() {
    return 'DeviceInfo{id: $id, type: $type, name: $name, platform: $platform}';
  }
}
