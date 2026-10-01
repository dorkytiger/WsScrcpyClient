import 'package:flutter/foundation.dart';
import 'package:ws_scrcpy_client/core/exception/global_exception.dart';
import 'package:ws_scrcpy_client/core/state/async_state.dart';

/// WebView 壳的状态与交互。
///
/// 这里只保存展示态（加载中/已加载/失败、能否后退），
/// `WebViewController` 属于平台视图对象，由 view 自己持有 —— viewmodel 不碰 UI 上下文。
class WebviewShellViewModel extends ChangeNotifier {
  AsyncState<Uri> _state = const AsyncLoading();
  bool _canGoBack = false;
  String? _lastErrorDetail;

  /// 加载三态（data 为当前地址）。
  AsyncState<Uri> get state => _state;

  /// 网页当前是否可后退（Android 返回键据此决定"网页后退"还是"退出页面"）。
  bool get canGoBack => _canGoBack;

  /// 失败时的技术细节（如 HTTP 状态码/平台错误描述），用于排查。
  String? get lastErrorDetail => _lastErrorDetail;

  void markLoading() {
    _state = const AsyncLoading();
    notifyListeners();
  }

  void markLoaded(Uri uri, {required bool canGoBack}) {
    _canGoBack = canGoBack;
    _lastErrorDetail = null;
    _state = AsyncSuccess<Uri>(uri);
    notifyListeners();
  }

  /// 记录网页资源加载失败。
  ///
  /// [isForMainFrame] 为 false 表示只是子资源（图片/JS）失败，此时不应该把整页判为错误。
  void markResourceError({
    required String description,
    required bool isForMainFrame,
  }) {
    _lastErrorDetail = description;
    if (!isForMainFrame) {
      notifyListeners();
      return;
    }
    _state = AsyncFailure<Uri>(RemoteException(message: '网页加载失败：$description'));
    notifyListeners();
  }

  void updateCanGoBack(bool value) {
    if (_canGoBack == value) {
      return;
    }
    _canGoBack = value;
    notifyListeners();
  }
}
