import 'package:flutter_test/flutter_test.dart';
import 'package:ws_scrcpy_client/core/stream/display_info.dart';
import 'package:ws_scrcpy_client/core/stream/video_settings.dart';
import 'package:ws_scrcpy_client/feature/stream/application/service/stream_session_service.dart';

/// 钉死四条"向服务端索要什么"的规则：
/// ① **绝不要求放大**（bounds 不许超过设备原生分辨率，AGENTS §12.7）；
/// ② **框的宽高比必须与设备一致**（服务端是按比例把画面装进框，框比例不对会把分辨率压死，
///    AGENTS §12.7 的 ★ 修正 / iOS 实测）；
/// ③ **一律向下对齐到 16×16 宏块**（§12.8：非对齐尺寸的流解码器解不出来）；
/// ④ 服务端没给 `VideoSettings` 时的回落值必须与服务端网页端的默认构造一致。
void main() {
  group('clampBoundsToNative：不放大 + 同设备宽高比 + 16 宏块对齐', () {
    const native = VideoSize(1280, 720);

    test('视口大于原生（1898x853）→ 收到原生满分辨率 1280x720', () {
      final clamped = StreamSessionService.clampBoundsToNative(
        viewport: const VideoSize(1898, 853),
        native: native,
      );
      // 先按设备比例把视口收成 1516x853 的框，再收到原生范围内 → 正好 1280x720。
      // 比"只做等比缩放"的 1280x560 多了 28% 的像素，而且宽高比与设备一致。
      expect(clamped, const VideoSize(1280, 720));
      expect(clamped.width, lessThanOrEqualTo(native.width));
      expect(clamped.height, lessThanOrEqualTo(native.height));
    });

    test('服务端自己给的 bounds 大于原生（1856x960）→ 同样收敛并对齐', () {
      final clamped = StreamSessionService.clampBoundsToNative(
        viewport: const VideoSize(1856, 960),
        native: native,
      );
      expect(clamped, const VideoSize(1280, 720));
      expect(clamped.width, lessThanOrEqualTo(native.width));
      expect(clamped.height, lessThanOrEqualTo(native.height));
    });

    test('视口小于原生 → 不放大，但仍要对齐且保持设备比例', () {
      // 800 宽的框按 16:9 得到 450 高（本来就不会超过视口的 600 高）→ 对齐到 800x448。
      expect(
        StreamSessionService.clampBoundsToNative(
          viewport: const VideoSize(800, 600),
          native: native,
        ),
        const VideoSize(800, 448),
      );
    });

    test('视口正好等于原生（本来就 16 对齐）→ 原样保留', () {
      expect(
        StreamSessionService.clampBoundsToNative(
          viewport: native,
          native: native,
        ),
        native,
      );
    });

    test('竖屏视口（720x1280）在横屏设备上 → 按设备比例收成 720x400', () {
      final clamped = StreamSessionService.clampBoundsToNative(
        viewport: const VideoSize(720, 1280),
        native: native,
      );
      // 老算法给的是 400x720 的竖框——服务端按比例装进去只剩 400x225，
      // 白扔了高度预算。现在框跟设备同比例，宽度吃满 720。
      expect(clamped, const VideoSize(720, 400));
      expect(clamped.width, lessThanOrEqualTo(native.width));
      expect(clamped.height, lessThanOrEqualTo(native.height));
    });

    test('回归：iPhone 竖屏 1206x1992 对横屏设备 1280x720（真机实测的"糊"）', () {
      final clamped = StreamSessionService.clampBoundsToNative(
        viewport: const VideoSize(1206, 1992),
        native: native,
      );
      // 老算法：432x720 的竖框 → 服务端装进去只剩 432x240（上屏放大 2.96 倍 = 糊）。
      // 只做"同比例收框 + 不放大"是 1200x672（像素多 7.7 倍）；**再叠上"贴原生就吸原生"**（2026-10-07）
      // 就是 1280x720 —— 顺带把"转屏要重建编码器"这件事消掉了（见下面那条测试）。
      expect(clamped, const VideoSize(1280, 720));
      expect(
        clamped.width * clamped.height,
        greaterThan(432 * 240 * 7),
        reason: '这条就是"画面糊"的回归门禁',
      );
    });

    test('★ 转屏（竖 1206x2094 ↔ 横 2622x1206）收敛成同一个边界：服务端不用重建编码器', () {
      // 用户实测"手机旋转一下屏幕就点不动了/要等几十秒"：转屏会改编码边界 → 服务端重建编码器
      // → 要等新的 IDR（iFrameInterval=10s）→ 画面停住。吸附到原生后两个方向都是原生尺寸，
      // service 的去重会直接吃掉第二条消息（配合真机日志 `视口诊断…下发 0 条`）。
      final portrait = StreamSessionService.clampBoundsToNative(
        viewport: const VideoSize(1206, 2094),
        native: native,
      );
      final landscape = StreamSessionService.clampBoundsToNative(
        viewport: const VideoSize(2622, 1206),
        native: native,
      );
      expect(portrait, const VideoSize(1280, 720));
      expect(landscape, const VideoSize(1280, 720));
      expect(portrait, landscape, reason: '转屏前后必须完全一致，否则每转一次就重建一次编码器');
    });

    test('视口明显小于原生时仍然不吸附（不许让小窗口白烧设备算力）', () {
      final clamped = StreamSessionService.clampBoundsToNative(
        viewport: const VideoSize(999, 601),
        native: native,
      );
      expect(
        clamped,
        const VideoSize(992, 560),
        reason: '992/1280=77.5% 低于吸附门槛 90%，保持不放大（AGENTS §12.7）',
      );
      expect(
        StreamSessionService.snapToNativeRatio,
        closeTo(0.9, 1e-9),
      );
    });

    test('收敛后的宽高比必须贴近设备宽高比（否则服务端会白扔像素）', () {
      const viewports = <VideoSize>[
        VideoSize(1898, 853),
        VideoSize(720, 1280),
        VideoSize(1206, 1992),
        VideoSize(800, 600),
        VideoSize(4000, 1000),
      ];
      for (final viewport in viewports) {
        final clamped = StreamSessionService.clampBoundsToNative(
          viewport: viewport,
          native: native,
        );
        final deviceRatio = native.width / native.height;
        final clampedRatio = clamped.width / clamped.height;
        // 向下对齐到 16 会带来一点比例损失，但必须远小于"框比例不对"的量级。
        expect(
          (clampedRatio - deviceRatio).abs(),
          lessThan(0.05),
          reason: '视口 $viewport 收敛成 $clamped 后比例偏离设备太多',
        );
      }
    });

    test('非法/退化输入不会算出 0 或负数', () {
      expect(
        StreamSessionService.clampBoundsToNative(
          viewport: const VideoSize(0, 0),
          native: native,
        ),
        native,
        reason: '视口非法时退回原生',
      );
      expect(
        StreamSessionService.clampBoundsToNative(
          viewport: const VideoSize(1000, 1000),
          native: const VideoSize(0, 0),
        ),
        const VideoSize(992, 992),
        reason: '原生尺寸未知时不动视口（不猜），但要对齐',
      );
      expect(
        StreamSessionService.clampBoundsToNative(
          viewport: const VideoSize(10, 10),
          native: native,
        ),
        const VideoSize(16, 16),
        reason: '极小视口对齐后不能变成 0',
      );
    });
  });

  group('alignToMacroblock：H.264 宏块是 16x16', () {
    test('向下对齐（绝不上抬，避免意外放大）', () {
      expect(
        StreamSessionService.alignToMacroblock(const VideoSize(1280, 575)),
        const VideoSize(1280, 560),
      );
      expect(
        StreamSessionService.alignToMacroblock(const VideoSize(1898, 853)),
        const VideoSize(1888, 848),
      );
      expect(
        StreamSessionService.alignToMacroblock(const VideoSize(16, 16)),
        const VideoSize(16, 16),
      );
      expect(
        StreamSessionService.alignToMacroblock(const VideoSize(1, 15)),
        const VideoSize(16, 16),
        reason: '小于一个宏块时给一个宏块，不能是 0',
      );
    });
  });

  group('服务端没给 VideoSettings 时的回落值（对齐 bundle 默认构造）', () {
    test(
      '全 0：bitrate 0 / maxFps 0 / iFrameInterval 0（不是本地默认 8000000 / 10）',
      () {
        final fallback = StreamSessionService.fallbackVideoSettings(0);
        expect(fallback.bitrate, 0);
        expect(fallback.maxFps, 0);
        expect(fallback.iFrameInterval, 0);
        expect(fallback.bounds, isNull);
        expect(fallback.sendFrameMeta, isFalse);
        // 注意：VideoSettings 自己的默认构造是 8000000/10（那是"本地默认"，
        // 与服务端网页端发给服务端的默认值不是一回事）——所以必须显式传 0。
        expect(fallback.bitrate, isNot(VideoSettings.defaultBitrate));
      },
    );

    test('★ 发出去之前用网页端 MSE 播放器的首选值补齐（bundle.js 实测值）', () {
      final fallback = StreamSessionService.fallbackVideoSettings(0);
      final filled = StreamSessionService.withWebPlayerPreferredDefaults(fallback);
      // 依据：bundle.js `MsePlayer.preferredVideoSettings = {bitrate: 7340032, maxFps: 60,
      // iFrameInterval: 10, ...}`。不补的话实测平均只有 ~0.6 Mbps / ~11fps → 画面又软又块。
      expect(filled.bitrate, StreamSessionService.webPlayerPreferredBitrate);
      expect(filled.bitrate, 7340032);
      expect(filled.maxFps, StreamSessionService.webPlayerPreferredMaxFps);
      expect(filled.maxFps, 60);
      expect(filled.iFrameInterval, StreamSessionService.webPlayerPreferredIFrameInterval);
      expect(filled.iFrameInterval, 10);
    });

    test('★ 服务端给了的字段必须原样回显，不能被本地值覆盖（§6.2 反馈循环教训）', () {
      final fromServer = StreamSessionService.withWebPlayerPreferredDefaults(
        const VideoSettings(bitrate: 1234567, maxFps: 15, iFrameInterval: 3),
      );
      expect(fromServer.bitrate, 1234567);
      expect(fromServer.maxFps, 15);
      expect(fromServer.iFrameInterval, 3);
    });
  });
}
