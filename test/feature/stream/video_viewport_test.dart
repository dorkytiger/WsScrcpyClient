import 'package:flutter_test/flutter_test.dart';
import 'package:ws_scrcpy_client/feature/stream/application/input/video_viewport.dart';

/// 触摸坐标换算错一点，设备上就"点哪偏哪"，所以这里把留黑边的情况钉死。
void main() {
  group('VideoViewport 横屏视频放进正方形容器（上下留黑边）', () {
    const viewport = VideoViewport(
      videoWidth: 1280,
      videoHeight: 720,
      viewWidth: 1000,
      viewHeight: 1000,
    );

    test('按宽缩放并居中', () {
      expect(viewport.scale, closeTo(1000 / 1280, 1e-9));
      expect(viewport.displayWidth, closeTo(1000, 1e-6));
      expect(viewport.displayHeight, closeTo(562.5, 1e-6));
      expect(viewport.offsetX, closeTo(0, 1e-6));
      expect(viewport.offsetY, closeTo((1000 - 562.5) / 2, 1e-6));
    });

    test('画面中心映射到视频中心', () {
      expect(viewport.toVideoPoint(500, 500), const VideoPoint(640, 360));
    });

    test('画面左上角映射到 (0,0)，右下角收进最后一个像素', () {
      final topLeft = viewport.toVideoPoint(viewport.offsetX, viewport.offsetY);
      expect(topLeft, isNotNull);
      expect(topLeft!.x, 0);
      expect(topLeft.y, 0);

      final bottomRight = viewport.toVideoPoint(
        viewport.offsetX + viewport.displayWidth,
        viewport.offsetY + viewport.displayHeight,
      );
      expect(bottomRight, const VideoPoint(1279, 719));
    });

    test('黑边上的点一律返回 null（不转发给设备）', () {
      expect(viewport.toVideoPoint(500, 10), isNull);
      expect(viewport.toVideoPoint(500, 995), isNull);
      expect(viewport.contains(500, 10), isFalse);
    });
  });

  group('VideoViewport 竖屏容器（16:9 视频按宽铺满，上下留黑边）', () {
    const viewport = VideoViewport(
      videoWidth: 1280,
      videoHeight: 720,
      viewWidth: 720,
      viewHeight: 1280,
    );

    test('按宽缩放，上下留黑边', () {
      expect(viewport.scale, closeTo(720 / 1280, 1e-9));
      expect(viewport.displayWidth, closeTo(720, 1e-6));
      expect(viewport.displayHeight, closeTo(405, 1e-6));
      expect(viewport.offsetX, closeTo(0, 1e-6));
      expect(viewport.offsetY, closeTo((1280 - 405) / 2, 1e-6));
      expect(viewport.toVideoPoint(360, 640), const VideoPoint(640, 360));
      // 上方黑边里
      expect(viewport.toVideoPoint(360, 5), isNull);
    });
  });

  group('VideoViewport 超宽容器（16:9 视频按高铺满，左右留黑边）', () {
    const viewport = VideoViewport(
      videoWidth: 1280,
      videoHeight: 720,
      viewWidth: 2000,
      viewHeight: 500,
    );

    test('按高缩放，左右留黑边', () {
      expect(viewport.scale, closeTo(500 / 720, 1e-9));
      expect(viewport.displayHeight, closeTo(500, 1e-6));
      expect(viewport.offsetY, closeTo(0, 1e-6));
      expect(viewport.offsetX, greaterThan(0));
      expect(viewport.toVideoPoint(1000, 250), const VideoPoint(640, 360));
      expect(viewport.toVideoPoint(10, 250), isNull);
    });
  });

  group('VideoViewport 边界情况', () {
    test('尺寸为 0 时不可用，且不返回坐标', () {
      const viewport = VideoViewport(
        videoWidth: 0,
        videoHeight: 0,
        viewWidth: 100,
        viewHeight: 100,
      );
      expect(viewport.isUsable, isFalse);
      expect(viewport.scale, 0);
      expect(viewport.toVideoPoint(50, 50), isNull);
    });

    test('极端宽高比也不会算出越界坐标', () {
      const viewport = VideoViewport(
        videoWidth: 2400,
        videoHeight: 1080,
        viewWidth: 100,
        viewHeight: 1000,
      );
      final point = viewport.toVideoPoint(50, 500);
      expect(point, isNotNull);
      expect(point!.x, inInclusiveRange(0, 2399));
      expect(point.y, inInclusiveRange(0, 1079));
    });
  });
}
