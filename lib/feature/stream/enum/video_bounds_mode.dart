/// 下发给设备的**编码边界策略**（`CHANGE_STREAM_PARAMETERS` 里的 `bounds`）。
///
/// 背景：`bounds` 是"请设备按这个框出图"的意思，而同一个 1280x720 的设备画面
/// 编成多少像素，直接决定客户端那边清不清晰：
///
/// - 编得少（例如 992x560）→ 本地放大 3 倍以上，肉眼就是糊；
/// - 编得多（例如 2560x1440）→ 本地几乎不放大，清晰，但**设备侧要真编这么多像素**
///   （redroid 容器里的软编码器压力大，实测过帧间隔被拖到 53–166ms，见 AGENTS §12.7）。
///
/// 服务端自带的网页端走的是第二种：它把**浏览器视口尺寸**当 `bounds` 发过去
/// （`getMaxSize()` 取 `document.body.clientWidth/clientHeight` 并对齐 16，
/// 既没有按 DPR 乘、也没有按设备原生封顶）——这就是"网页端看着更清楚"的机制。
///
/// 本项目原来只有第一种，理由是 §12.7 那次"要更多像素 → 设备编码器卡成幻灯片"；
/// 但那是**显示层该不该放大**的取舍，不该由我们替用户一刀切，所以做成开关。
enum VideoBoundsMode {
  /// 省设备算力：编码边界**不超过设备原生分辨率**（默认行为，AGENTS §12.7）。
  nativeCap('省设备算力', '上限=设备原生，设备少编像素；画面靠本地放大，可能偏糊'),

  /// 清晰优先：按**画面区的物理像素**要，最多到原生分辨率的 [maxUpscale] 倍
  /// （与网页端的做法一致；设备侧编码压力更大，掉帧风险更高）。
  viewport('清晰优先', '按画面区物理像素编码，最多到原生 2 倍：更清晰，设备更吃力');

  const VideoBoundsMode(this.label, this.description);

  /// UI 用的中文名。
  final String label;

  /// UI 用的说明（为什么要有这个开关、代价是什么）。
  final String description;

  /// 清晰优先时的硬上限：原生分辨率的倍数。
  ///
  /// 为什么要上限：窗口在 Retina 大屏上可以到 3000+ 物理像素宽，原样要过去
  /// 会让容器里的软编码器直接崩掉帧率；2 倍（1280x720 → 2560x1440）已经能把
  /// "放大 2.7 倍"压到"几乎 1:1"，收益吃满了，再往上只有代价。
  static const int maxUpscale = 2;

  VideoBoundsMode get toggled =>
      this == VideoBoundsMode.nativeCap ? VideoBoundsMode.viewport : nativeCap;
}
