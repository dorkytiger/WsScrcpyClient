import 'dart:math';

/// 断线重连退避策略：指数增长 + 抖动，避免多客户端同时重连把服务端打满。
class ReconnectPolicy {
  const ReconnectPolicy({
    this.initialDelay = const Duration(milliseconds: 500),
    this.maxDelay = const Duration(seconds: 20),
    this.multiplier = 2,
    this.jitterRatio = 0.2,
    this.random,
  });

  final Duration initialDelay;
  final Duration maxDelay;
  final double multiplier;

  /// 抖动比例（0~1）：最终延迟在 `[delay*(1-r), delay]` 之间。
  final double jitterRatio;

  /// 可注入随机源，便于单元测试得到确定结果。
  final Random? random;

  /// 第 [attempt] 次重试（从 0 开始）应等待的时长。
  Duration delayForAttempt(int attempt) {
    final safeAttempt = attempt < 0 ? 0 : attempt;
    final raw = initialDelay.inMilliseconds * pow(multiplier, safeAttempt);
    final capped = raw.isFinite ? raw : maxDelay.inMilliseconds.toDouble();
    final limited = min(capped, maxDelay.inMilliseconds.toDouble());
    final jitter = (random ?? Random()).nextDouble() * jitterRatio;
    final delay = limited * (1 - jitter);
    return Duration(
      milliseconds: delay.round().clamp(0, maxDelay.inMilliseconds),
    );
  }
}
