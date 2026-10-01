import 'package:flutter_test/flutter_test.dart';
import 'package:ws_scrcpy_client/core/stream/display_info.dart';
import 'package:ws_scrcpy_client/core/stream/video_settings.dart';
import 'package:ws_scrcpy_client/feature/stream/application/service/stream_session_service.dart';

/// 钉死三条"向服务端索要什么"的规则：
/// ① **绝不要求放大**（bounds 不许超过设备原生分辨率，AGENTS §12.7）；
/// ② **一律向下对齐到 16×16 宏块**（§12.8：非对齐尺寸的流解码器解不出来）；
/// ③ 服务端没给 `VideoSettings` 时的回落值必须与服务端网页端的默认构造一致。
void main() {
  group('clampBoundsToNative：绝不放大 + 16 宏块对齐', () {
    const native = VideoSize(1280, 720);

    test('视口大于原生（1898x853）→ 收敛并向下对齐到 1280x560', () {
      final clamped = StreamSessionService.clampBoundsToNative(
        viewport: const VideoSize(1898, 853),
        native: native,
      );
      // 真机场景：设备 1280x720，UI 视口 1898x853。
      // 等比收敛本来得到 1280x575（奇数），MF 解不出来（§12.8 真机实测），
      // 向下对齐到 16 的倍数后是 1280x560。
      expect(clamped, const VideoSize(1280, 560));
      expect(clamped.width, lessThanOrEqualTo(native.width));
      expect(clamped.height, lessThanOrEqualTo(native.height));
      // 对齐会带来很小的宽高比损失（最多 15/16 个宏块，这里 853→848 那一档约 0.06），
      // 但不能大到"明显变形"。
      final sourceRatio = 1898 / 853;
      final clampedRatio = clamped.width / clamped.height;
      expect((sourceRatio - clampedRatio).abs(), lessThan(0.07));
    });

    test('服务端自己给的 bounds 大于原生（1856x960）→ 同样收敛并对齐', () {
      final clamped = StreamSessionService.clampBoundsToNative(
        viewport: const VideoSize(1856, 960),
        native: native,
      );
      expect(clamped, const VideoSize(1280, 656));
      expect(clamped.width, lessThanOrEqualTo(native.width));
      expect(clamped.height, lessThanOrEqualTo(native.height));
    });

    test('视口小于原生 → 不放大，但仍要对齐', () {
      expect(
        StreamSessionService.clampBoundsToNative(
          viewport: const VideoSize(800, 600),
          native: native,
        ),
        const VideoSize(800, 592),
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

    test('竖屏视口（720x1280）在横屏设备上 → 按高收敛，且对齐', () {
      final clamped = StreamSessionService.clampBoundsToNative(
        viewport: const VideoSize(720, 1280),
        native: native,
      );
      expect(clamped, const VideoSize(400, 720));
      expect(clamped.width, lessThanOrEqualTo(native.width));
      expect(clamped.height, lessThanOrEqualTo(native.height));
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
  });
}
