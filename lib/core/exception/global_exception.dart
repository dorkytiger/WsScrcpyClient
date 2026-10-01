/// 全局异常体系：所有跨层错误统一用 [GlobalException] 的子类表达，
/// 禁止在业务代码里裸抛 `Exception('...')`。
sealed class GlobalException implements Exception {
  const GlobalException({
    required this.message,
    this.exception,
    this.stackTrace,
  });

  /// 可直接展示给用户的中文文案。
  final String message;

  /// 原始异常 / 详细信息，用于日志排查。
  final Object? exception;

  final StackTrace? stackTrace;

  @override
  String toString() =>
      '$runtimeType: $message${exception == null ? '' : ' | cause: $exception'}';
}

/// 远程请求（HTTP / WebSocket）失败。
class RemoteException extends GlobalException {
  const RemoteException({
    super.message = '远程请求错误',
    super.exception,
    super.stackTrace,
  });
}

/// 本地持久化（安全存储 / 文件）失败。
class LocalStorageException extends GlobalException {
  const LocalStorageException({
    super.message = '本地数据操作失败',
    super.exception,
    super.stackTrace,
  });
}

/// 入参校验失败。
class ValidationException extends GlobalException {
  const ValidationException({
    super.message = '参数不合法',
    super.exception,
    super.stackTrace,
  });
}

/// 业务规则失败。
class BusinessException extends GlobalException {
  const BusinessException({
    super.message = '业务处理失败',
    super.exception,
    super.stackTrace,
  });
}

/// 协议/响应解析失败：字段缺失、长度不足、类型不符等。
class ParsingException extends GlobalException {
  const ParsingException({
    super.message = '数据解析失败',
    super.exception,
    super.stackTrace,
  });
}
