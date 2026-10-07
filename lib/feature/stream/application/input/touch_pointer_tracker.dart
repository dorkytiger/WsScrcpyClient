import 'package:ws_scrcpy_client/core/control/touch_control_message.dart';
import 'package:ws_scrcpy_client/feature/stream/application/input/video_viewport.dart';

/// 一次触摸事件的"计划"里要发出的一条消息。
class TouchStep {
  const TouchStep(this.action, this.point);

  final TouchAction action;
  final VideoPoint point;

  @override
  bool operator ==(Object other) =>
      other is TouchStep && other.action == action && other.point == point;

  @override
  int get hashCode => Object.hash(action, point);

  @override
  String toString() => '${action.name}(${point.x},${point.y})';
}

/// [TouchPointerTracker.handle] 的结果：要么发一串消息，要么整条忽略并给出原因。
class TouchPlan {
  const TouchPlan.send(this.steps) : ignoredReason = null;
  const TouchPlan.ignore(this.ignoredReason) : steps = const <TouchStep>[];

  /// 按顺序要发出的消息（最多两条：黑边上划走时是"补一条 UP"）。
  final List<TouchStep> steps;

  /// 整条被忽略时的原因（用于日志）。
  final String? ignoredReason;

  bool get isIgnored => ignoredReason != null;

  @override
  String toString() =>
      isIgnored ? 'TouchPlan.ignore($ignoredReason)' : 'TouchPlan.send($steps)';
}

/// 触摸指针状态机：**保证每一个 DOWN 都有且只有一个配对的 UP**。
///
/// ## 为什么必须有它（2026-10-02，iOS 实测"点几下就点不动了"）
///
/// 设备端（`scrcpy-server` → Android `InputDispatcher`）是**按 `pointerId` 记**
/// "这根手指是否还按着"的。只要某根手指只收到 `DOWN`、没收到 `UP`，
/// 设备就会一直认为它按着；之后**复用同一个 pointerId** 的 `DOWN` 会被直接丢弃。
///
/// 现象就正好是用户报的那句："一开始可能可以，试几次就点不回去了"——
/// 卡住的那个 id 会被 Flutter 反复复用，于是**所有单指操作**都失效。
///
/// 我们原来最容易漏 UP 的地方是**黑边**：按下时手指在画面内、抬起时滑到了上下的黑边上，
/// 而视图层对"落在黑边"的事件一律不转发（`_sendTouch` 里 `point == null` 就 return），
/// 那条 UP 被整条吃掉。iOS 竖屏时画面只占控件高度的约 1/3，
/// **滑动几乎必然滑出画面**，所以这是必现问题，不是偶发。
///
/// ## 规则（逐条对照服务端网页端 `buildTouchOnClient` + `validateMessage`）
///
/// | 事件 | 该 id 未按下 | 已按下 |
/// |---|---|---|
/// | `DOWN` | 落画面内 → 记下坐标并放行；落黑边 → **丢弃**（这次按下没成立，也没有 UP 要补） | **丢弃**（重复 DOWN 会让设备多按下一根手指） |
/// | `MOVE` | **丢弃**（不凭空造一次点击） | 落画面内 → 更新坐标并放行；落黑边 → **补一条 UP 释放它**（网页端也是这么做的） |
/// | `UP` / `CANCEL` | **丢弃**（没有配对的按下） | **一定发出**——点落在黑边上就用最后一次有效坐标，绝不因为坐标不合法而吃掉 UP |
///
/// 坐标的"最后一次有效值"在 DOWN 时记下，MOVE 时更新，仅用于 UP 的兜底。
class TouchPointerTracker {
  /// 已按下、还没抬起的指针：id → 最后一次有效坐标。
  final Map<int, VideoPoint> _downPointers = <int, VideoPoint>{};

  /// 当前按下的指针数量（诊断/测试用）。
  int get activePointerCount => _downPointers.length;

  /// 某个指针是否处于按下状态（诊断/测试用）。
  bool isDown(int pointerId) => _downPointers.containsKey(pointerId);

  /// 断开/重连时清空：新会话的设备端是干净的，本地的陈旧状态只会误判。
  void reset() => _downPointers.clear();

  /// 处理一条指针事件，返回该发什么（或为什么忽略）。
  ///
  /// [point] 为 null 表示这次事件落在黑边上（或视口不可用）。
  TouchPlan handle({
    required TouchAction action,
    required int pointerId,
    required VideoPoint? point,
  }) {
    switch (action) {
      case TouchAction.down:
        if (_downPointers.containsKey(pointerId)) {
          return TouchPlan.ignore('id=$pointerId 已经按下，重复 DOWN 会让设备多按一根手指');
        }
        if (point == null) {
          return TouchPlan.ignore('按下落在黑边上（这次按下不成立，也就没有 UP 要补）');
        }
        _downPointers[pointerId] = point;
        return TouchPlan.send(<TouchStep>[TouchStep(TouchAction.down, point)]);

      case TouchAction.move:
        final lastPoint = _downPointers[pointerId];
        if (lastPoint == null) {
          // 没有 DOWN 的 MOVE：服务端网页端会补一条"模拟 DOWN"，我们更保守——
          // 直接忽略。凭空造一次点击比"这次拖动没生效"糟糕得多。
          return TouchPlan.ignore('id=$pointerId 没有按下的 MOVE（已忽略，不凭空造点击）');
        }
        if (point == null) {
          // 手指划到黑边上：**必须补一条 UP 释放**，否则这个 id 会被永久卡住。
          _downPointers.remove(pointerId);
          return TouchPlan.send(<TouchStep>[
            TouchStep(TouchAction.up, lastPoint),
          ]);
        }
        _downPointers[pointerId] = point;
        return TouchPlan.send(<TouchStep>[TouchStep(TouchAction.move, point)]);

      case TouchAction.up:
        final lastPoint = _downPointers.remove(pointerId);
        if (lastPoint == null) {
          return TouchPlan.ignore('id=$pointerId 没有按下的 UP（已忽略）');
        }
        // 关键：UP 用"最后一次有效坐标"兜底，**绝不因为这次落点不合法而吃掉 UP**。
        return TouchPlan.send(<TouchStep>[
          TouchStep(TouchAction.up, point ?? lastPoint),
        ]);
    }
  }
}
