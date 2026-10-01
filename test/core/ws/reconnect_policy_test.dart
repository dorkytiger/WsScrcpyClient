import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ws_scrcpy_client/core/ws/reconnect_policy.dart';

void main() {
  group('ReconnectPolicy', () {
    test('延迟按倍数增长并受 maxDelay 限制', () {
      final policy = ReconnectPolicy(
        initialDelay: const Duration(milliseconds: 500),
        maxDelay: const Duration(seconds: 8),
        jitterRatio: 0,
        random: Random(1),
      );

      expect(policy.delayForAttempt(0).inMilliseconds, 500);
      expect(policy.delayForAttempt(1).inMilliseconds, 1000);
      expect(policy.delayForAttempt(2).inMilliseconds, 2000);
      expect(policy.delayForAttempt(3).inMilliseconds, 4000);
      // 第 4 次理论 8000，正好等于上限；再往后必须被截断在上限。
      expect(policy.delayForAttempt(4).inMilliseconds, 8000);
      expect(policy.delayForAttempt(10).inMilliseconds, 8000);
    });

    test('抖动落在 [delay*(1-r), delay] 区间内', () {
      final policy = ReconnectPolicy(
        initialDelay: const Duration(seconds: 1),
        maxDelay: const Duration(seconds: 30),
        jitterRatio: 0.2,
        random: Random(42),
      );

      for (var attempt = 0; attempt < 5; attempt++) {
        final base = policy.delayForAttempt(0).inMilliseconds;
        final delay = policy.delayForAttempt(attempt).inMilliseconds;
        final expectedBase = 1000 * pow(2, attempt);
        expect(delay, greaterThanOrEqualTo((expectedBase * 0.8).floor()));
        expect(delay, lessThanOrEqualTo(expectedBase.ceil()));
        expect(base, greaterThan(0));
      }
    });

    test('非法重试次数按 0 处理', () {
      final policy = ReconnectPolicy(
        initialDelay: const Duration(milliseconds: 300),
        jitterRatio: 0,
        random: Random(7),
      );
      expect(policy.delayForAttempt(-3).inMilliseconds, 300);
    });
  });
}
