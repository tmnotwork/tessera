import 'dart:html' as html;

typedef WebStorageListener = void Function(String key, String? newValue);

void attachWebStorageListener(WebStorageListener listener) {
  try {
    html.window.onStorage.listen((event) {
      try {
        final key = event.key;
        if (key == null) return;
        listener(key, event.newValue);
      } catch (_) {}
    });
  } catch (_) {
    // localStorage が使えない環境（Safariプライベート等）では無視
  }
}

String? readWebStorage(String key) {
  try {
    return html.window.localStorage[key];
  } catch (_) {
    return null;
  }
}

void writeWebStorage(String key, String value) {
  try {
    html.window.localStorage[key] = value;
  } catch (_) {
    // localStorage が使えない環境（Safariプライベート等）では無視
  }
}

bool isPageHidden() {
  try {
    return html.document.hidden ?? false;
  } catch (_) {
    return false;
  }
}

