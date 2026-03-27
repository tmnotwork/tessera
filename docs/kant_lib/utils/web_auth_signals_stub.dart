typedef WebStorageListener = void Function(String key, String? newValue);

/// Web以外では localStorage は存在しないため、空実装。
void attachWebStorageListener(WebStorageListener listener) {}

String? readWebStorage(String key) => null;

void writeWebStorage(String key, String value) {}

bool isPageHidden() => false;

