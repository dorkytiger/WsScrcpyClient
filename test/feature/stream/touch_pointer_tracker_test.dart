import 'package:flutter_test/flutter_test.dart';
import 'package:ws_scrcpy_client/core/control/touch_control_message.dart';
import 'package:ws_scrcpy_client/feature/stream/application/input/touch_pointer_tracker.dart';
import 'package:ws_scrcpy_client/feature/stream/application/input/video_viewport.dart';

/// 钉死一条铁律：**每一个 DOWN 都必须有且只有一个配对的 UP**。
///
/// 背景（2026-10-02，iOS 实测）：设备端按 `pointerId` 记"这根手指是否还按着"。
/// 只要有 DOWN 没配对的 UP，那个 id 就被永久卡住，之后所有复用该 id 的单指操作
/// 全部失效 —— 用户的原话是"一开始可能可以，试几次就点不回去了"。
/// 最容易漏 UP 的场景是**手指从画面内滑到黑边上**（iOS 竖屏时画面只占控件高度约 1/3）。
void main() {
  group('TouchPointerTracker：DOWN/UP 必须配对', () {
    late TouchPointerTracker tracker;

    setUp(() => tracker = TouchPointerTracker());

    const inside = VideoPoint(100, 100);
    const inside2 = VideoPoint(120, 130);

    test('画面内的 down/move/up → 原样放行，且状态归零', () {
      expect(
        tracker
            .handle(action: TouchAction.down, pointerId: 7, point: inside)
            .steps,
        const <TouchStep>[TouchStep(TouchAction.down, inside)],
      );
      expect(tracker.isDown(7), isTrue);

      expect(
        tracker
            .handle(action: TouchAction.move, pointerId: 7, point: inside2)
            .steps,
        const <TouchStep>[TouchStep(TouchAction.move, inside2)],
      );

      expect(
        tracker
            .handle(action: TouchAction.up, pointerId: 7, point: inside2)
            .steps,
        const <TouchStep>[TouchStep(TouchAction.up, inside2)],
      );
      expect(tracker.isDown(7), isFalse);
      expect(tracker.activePointerCount, 0);
    });

    test('★ 回归：按下在画面内、抬起滑到黑边上 → 仍然要发一条 UP 释放', () {
      tracker.handle(action: TouchAction.down, pointerId: 0, point: inside);
      // 手指滑到黑边（point == null）——原来的实现会在这里把整条事件吃掉，
      // 于是设备端永远认为 id=0 按着。
      final plan = tracker.handle(
        action: TouchAction.up,
        pointerId: 0,
        point: null,
      );

      expect(plan.isIgnored, isFalse, reason: 'UP 绝不能被丢掉');
      expect(plan.steps, hasLength(1));
      expect(plan.steps.single.action, TouchAction.up);
      // 用"最后一次有效坐标"兜底，而不是把非法坐标发过去。
      expect(plan.steps.single.point, inside);
      expect(tracker.isDown(0), isFalse, reason: '状态必须清掉，否则这个 id 就废了');
    });

    test('★ 回归：滑动滑出画面（MOVE 落黑边）→ 立刻补一条 UP 释放', () {
      tracker.handle(action: TouchAction.down, pointerId: 3, point: inside);
      final plan = tracker.handle(
        action: TouchAction.move,
        pointerId: 3,
        point: null,
      );

      expect(plan.isIgnored, isFalse);
      expect(plan.steps.single.action, TouchAction.up);
      expect(plan.steps.single.point, inside);
      expect(tracker.isDown(3), isFalse);

      // 释放之后再来一次点按，必须还能发 DOWN（这就是"点不动了"的反面）。
      final next = tracker.handle(
        action: TouchAction.down,
        pointerId: 3,
        point: inside2,
      );
      expect(next.steps.single.action, TouchAction.down);
    });

    test('重复 DOWN 被丢弃（否则设备会以为多按了一根手指）', () {
      tracker.handle(action: TouchAction.down, pointerId: 1, point: inside);
      final again = tracker.handle(
        action: TouchAction.down,
        pointerId: 1,
        point: inside2,
      );
      expect(again.isIgnored, isTrue);
      expect(again.ignoredReason, contains('已经按下'));
      // 原始状态不能被第二次 DOWN 覆盖。
      expect(tracker.isDown(1), isTrue);
    });

    test('没有按下的 UP / MOVE 被丢弃（不凭空造点击）', () {
      expect(
        tracker
            .handle(action: TouchAction.up, pointerId: 9, point: inside)
            .isIgnored,
        isTrue,
      );
      expect(
        tracker
            .handle(action: TouchAction.move, pointerId: 9, point: inside)
            .isIgnored,
        isTrue,
      );
      expect(tracker.activePointerCount, 0);
    });

    test('按下就落在黑边上 → 丢弃这次按下（没成立，也就没有 UP 要补）', () {
      final plan = tracker.handle(
        action: TouchAction.down,
        pointerId: 5,
        point: null,
      );
      expect(plan.isIgnored, isTrue);
      expect(tracker.isDown(5), isFalse);
    });

    test('多指互不干扰：一根滑出画面被释放，另一根继续', () {
      tracker.handle(action: TouchAction.down, pointerId: 1, point: inside);
      tracker.handle(action: TouchAction.down, pointerId: 2, point: inside2);
      expect(tracker.activePointerCount, 2);

      final release = tracker.handle(
        action: TouchAction.move,
        pointerId: 1,
        point: null,
      );
      expect(release.steps.single.action, TouchAction.up);
      expect(tracker.isDown(1), isFalse);
      expect(tracker.isDown(2), isTrue, reason: '另一根手指不该被牵连');

      final stillMoving = tracker.handle(
        action: TouchAction.move,
        pointerId: 2,
        point: inside,
      );
      expect(stillMoving.steps.single.action, TouchAction.move);
    });

    test('reset 清空全部状态（断线/重连时用）', () {
      tracker.handle(action: TouchAction.down, pointerId: 1, point: inside);
      tracker.handle(action: TouchAction.down, pointerId: 2, point: inside);
      tracker.reset();
      expect(tracker.activePointerCount, 0);
      // 清空之后同一个 id 能重新按下。
      expect(
        tracker
            .handle(action: TouchAction.down, pointerId: 1, point: inside)
            .steps
            .single
            .action,
        TouchAction.down,
      );
    });

    test('连续 N 次点按之后仍能发 DOWN（"点几下就点不动"的反面）', () {
      for (var i = 0; i < 20; i++) {
        final down = tracker.handle(
          action: TouchAction.down,
          pointerId: 0,
          point: inside,
        );
        expect(down.steps.single.action, TouchAction.down, reason: '第 $i 次点按');
        // 第 i 次点按的 UP 故意落在黑边上（模拟手滑）。
        final up = tracker.handle(
          action: TouchAction.up,
          pointerId: 0,
          point: i.isEven ? null : inside,
        );
        expect(up.steps.single.action, TouchAction.up, reason: '第 $i 次抬起');
      }
      expect(tracker.activePointerCount, 0);
    });
  });
}
