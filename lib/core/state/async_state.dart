import 'package:ws_scrcpy_client/core/exception/global_exception.dart';

/// 通用三态状态机：loading / success / error（+ 空态由 success 的数据自行判断）。
///
/// 规范要求任何查询都必须有完整三态，禁止用一个页面里散落的布尔量表达。
sealed class AsyncState<T> {
  const AsyncState();
}

/// 进行中。
class AsyncLoading<T> extends AsyncState<T> {
  const AsyncLoading();
}

/// 成功（数据可能为空集合，由视图渲染空态）。
class AsyncSuccess<T> extends AsyncState<T> {
  const AsyncSuccess(this.data);

  final T data;
}

/// 失败：必须带可读文案，视图必须提供重试入口。
class AsyncFailure<T> extends AsyncState<T> {
  const AsyncFailure(this.error);

  final GlobalException error;
}
