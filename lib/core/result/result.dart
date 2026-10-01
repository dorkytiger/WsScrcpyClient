import 'package:ws_scrcpy_client/core/exception/global_exception.dart';

/// 跨层统一返回包装：可能失败的操作一律返回 [Result]，禁止 `void doXxx()` + 裸抛。
///
/// 上层拿到后必须先判 [isError] 再取 [data]，禁止强行解包。
///
/// 说明：全局规范里的示例写法是 `static Result<T> error<T>(...)`，
/// 但 Dart 不允许静态成员与实例字段同名（`error`），因此构造入口命名为
/// [failure]；实例侧仍保持 `data` / `error` / `isSuccess` / `isError` 契约不变。
class Result<T> {
  const Result._({this.data, this.error});

  final T? data;
  final GlobalException? error;

  bool get isSuccess => error == null;

  bool get isError => error != null;

  static Result<T> success<T>(T data) => Result<T>._(data: data);

  static Result<T> failure<T>(GlobalException error) =>
      Result<T>._(error: error);
}

/// `Result<void>` 场景（无返回值但可能失败）的便捷写法。
Result<void> successVoid() => const Result<void>._();

Result<void> failureVoid(GlobalException error) => Result<void>._(error: error);
