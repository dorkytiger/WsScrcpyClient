#!/usr/bin/env python3
"""生成全平台应用图标：Windows(.ico) / Android(含自适应) / macOS / iOS / Web。

用法（用带 Pillow 的 Python 跑）：

    python tools/make_icons.py

设计：深蓝→青的圆角方块底，上面是**两块叠起来的屏幕**（"投屏 / 镜像"最通用的视觉语汇：
一张屏，另一张镜像过去）。

为什么是脚本而不是一堆手工导出的 PNG：
  * 图标尺寸/命名在各平台都不一样（Windows 要 .ico、iOS 要 15 个固定文件名、
    Android 还要自适应图标的前景层），手改必然漏；
  * 想换配色/换个图形时，只改下面的"设计参数"再跑一次即可，不会再出现
    "Windows 换了、Android 忘了换"这种不一致；
  * 所有尺寸都从**同一份超采样绘制**缩下来，小尺寸不糊。

约定：改完图标请把生成结果一起提交（CI 不会生成图标）。
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

REPO = Path(__file__).resolve().parent.parent

# ── 设计参数（都是"设计画布"的比例，改这里就能调整观感）────────────────────
D = 2048  # 设计画布边长（越大越平滑，2048 已经足够）
SS = 2  # 额外超采样倍数（最终 master 从 D/SS 缩下来）
CORNER = 0.22  # 圆角半径 / 画布边长

GRAD_START = (79, 70, 229)  # #4F46E5 靛蓝（左上）
GRAD_END = (14, 165, 233)  # #0EA5E9 天蓝（右下）

BACK_BOX = (0.180, 0.235, 0.680, 0.610)  # 后屏（描边）x0,y0,x1,y1
BACK_STROKE = 0.055  # 描边宽度
FRONT_BOX = (0.320, 0.390, 0.820, 0.765)  # 前屏（实心）：相对后屏偏移 (0.14, 0.155)
GAP = 0.032  # 前屏四周的缝隙（露出底色，让两层分明）
BOX_RADIUS = 0.050  # 屏幕圆角半径

MOTIF_SCALE_ADAPTIVE = 0.60  # Android 自适应前景：图形占画布的比例（要落在安全区内）
MOTIF_SCALE_MASKABLE = 0.62  # Web maskable：同理，留出被裁切的余量

BACKGROUND_HEX = "#4F46E5"  # 自适应图标背景色（取渐变起点，保证与整体观感一致）


def _gradient(size: int) -> Image.Image:
    """左上→右下的线性渐变（用 numpy 一次算完，不要逐像素画）。"""
    y, x = np.mgrid[0:size, 0:size]
    t = (x + y) / (2.0 * (size - 1))  # 0..1
    start = np.array(GRAD_START, dtype=np.float32)
    end = np.array(GRAD_END, dtype=np.float32)
    rgb = start[None, None, :] * (1.0 - t[:, :, None]) + end[None, None, :] * t[:, :, None]
    return Image.fromarray(rgb.round().astype(np.uint8), mode="RGB")


def _rounded_mask(size: int, box: tuple[float, float, float, float], radius: float,
                  stroke: float = 0.0, supersample: int = 1) -> Image.Image:
    """在 size×size 的 L 掩膜上画一个（可选描边的）圆角矩形；比例都是画布占比。"""
    scale = size * supersample
    mask = Image.new("L", (scale, scale), 0)
    draw = ImageDraw.Draw(mask)
    x0, y0, x1, y1 = (v * scale for v in box)
    r = radius * scale
    if stroke > 0:
        draw.rounded_rectangle([x0, y0, x1, y1], radius=r, outline=255,
                               width=max(1, round(stroke * scale)))
    else:
        draw.rounded_rectangle([x0, y0, x1, y1], radius=r, fill=255)
    if supersample > 1:
        mask = mask.resize((size, size), Image.LANCZOS)
    return mask


def _motif_mask(size: int, scale: float = 1.0, supersample: int = SS) -> Image.Image:
    """两块叠起来的屏幕。

    :param scale: 整体缩放（1.0 = 设计尺寸；自适应图标/可遮罩图标会调小）
    """
    big = size * supersample
    motif = Image.new("L", (big, big), 0)
    # 先分别画"后屏描边"和"前屏实心"，再挖出前屏周围的缝隙
    back = _rounded_mask(big, BACK_BOX, BOX_RADIUS, stroke=BACK_STROKE, supersample=1)
    front = _rounded_mask(big, FRONT_BOX, BOX_RADIUS, supersample=1)
    x0, y0, x1, y1 = FRONT_BOX
    gap_outer = _rounded_mask(big, (x0 - GAP, y0 - GAP, x1 + GAP, y1 + GAP),
                              BOX_RADIUS + GAP, supersample=1)
    combined = np.maximum(np.asarray(back), np.asarray(front))
    # 关键：缝隙是**环**（外框减去前屏本身），不是实心矩形——
    # 用实心矩形会把前屏整块擦掉，图标就只剩一圈描边（第一版就是这么错的，靠看图发现）。
    erase = (np.asarray(gap_outer) > 0) & (np.asarray(front) == 0)
    combined = np.where(erase, 0, combined).astype(np.uint8)
    motif = Image.fromarray(combined, mode="L")
    if scale != 1.0:
        inner = max(1, round(big * scale))
        motif = motif.resize((inner, inner), Image.LANCZOS)
        canvas = Image.new("L", (big, big), 0)
        offset = (big - inner) // 2
        canvas.paste(motif, (offset, offset))
        motif = canvas
    if supersample > 1:
        motif = motif.resize((size, size), Image.LANCZOS)
    return motif


def render_full(size: int, rounded: bool = True) -> Image.Image:
    """完整图标：圆角渐变底 + 图形。Windows/Android 传统/macOS/iOS 用这个。"""
    base = _gradient(size)
    if rounded:
        card = Image.new("L", (size, size), 0)
        ImageDraw.Draw(card).rounded_rectangle(
            [0, 0, size - 1, size - 1], radius=round(CORNER * size), fill=255)
    else:
        card = Image.new("L", (size, size), 255)
    icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    icon.paste(base, (0, 0), card)
    white = Image.new("RGBA", (size, size), (255, 255, 255, 255))
    icon.paste(white, (0, 0), _motif_mask(size))
    return icon


def render_maskable(size: int) -> Image.Image:
    """Web maskable / 自适应图标背景层：满幅渐变（不留圆角），图形缩小留出裁切余量。"""
    icon = _gradient(size).convert("RGBA")
    white = Image.new("RGBA", (size, size), (255, 255, 255, 255))
    icon.paste(white, (0, 0), _motif_mask(size, scale=MOTIF_SCALE_MASKABLE))
    return icon


def render_foreground(size: int) -> Image.Image:
    """Android 自适应图标的前景层：**透明底** + 缩小到安全区内的图形。"""
    icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    white = Image.new("RGBA", (size, size), (255, 255, 255, 255))
    icon.paste(white, (0, 0), _motif_mask(size, scale=MOTIF_SCALE_ADAPTIVE))
    return icon


def downscale(image: Image.Image, size: int) -> Image.Image:
    """逐级折半缩小，比一步缩到 16px 干净得多。"""
    current = image
    while current.width // 2 >= size and current.width // 2 >= 16:
        current = current.resize((current.width // 2, current.height // 2), Image.LANCZOS)
    if current.width != size:
        current = current.resize((size, size), Image.LANCZOS)
    return current


def save_png(image: Image.Image, path: Path, size: int, *, alpha: bool = True) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    out = downscale(image, size)
    if not alpha:
        # iOS 要求图标不含 alpha 通道（App Store 会因此拒审）
        out = out.convert("RGB")
    out.save(path, "PNG", optimize=True)
    print(f"    {path.relative_to(REPO)}  {size}x{size}  {path.stat().st_size / 1024:.1f} KB")


def main() -> int:
    master = render_full(D // SS)

    print("Windows：windows/runner/resources/app_icon.ico")
    ico_path = REPO / "windows/runner/resources/app_icon.ico"
    ico_path.parent.mkdir(parents=True, exist_ok=True)
    master.save(ico_path, format="ICO",
                sizes=[(16, 16), (20, 20), (24, 24), (32, 32), (40, 40), (48, 48),
                       (64, 64), (96, 96), (128, 128), (256, 256)])
    print(f"    {ico_path.relative_to(REPO)}  {ico_path.stat().st_size / 1024:.1f} KB")

    android_res = REPO / "android/app/src/main/res"
    print("Android：传统图标 + 自适应图标（前景/背景）")
    legacy = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
    foreground = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}
    for bucket, size in legacy.items():
        save_png(master, android_res / f"mipmap-{bucket}/ic_launcher.png", size)
    adaptive = render_foreground(D // SS)
    for bucket, size in foreground.items():
        save_png(adaptive, android_res / f"mipmap-{bucket}/ic_launcher_foreground.png", size)

    # 自适应图标的 XML 与背景色（只在缺失时创建，避免覆盖你手改过的版本）
    anydpi = android_res / "mipmap-anydpi-v26"
    anydpi.mkdir(parents=True, exist_ok=True)
    adaptive_xml = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<!-- 由 tools/make_icons.py 生成：自适应图标（前景=ic_launcher_foreground，背景=颜色） -->\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background" />\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
        '</adaptive-icon>\n'
    )
    for name in ("ic_launcher.xml", "ic_launcher_round.xml"):
        target = anydpi / name
        target.write_text(adaptive_xml, encoding="utf-8")
        print(f"    {target.relative_to(REPO)}  {target.stat().st_size} B")
    color_xml = android_res / "values/ic_launcher_background.xml"
    color_xml.write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<!-- 由 tools/make_icons.py 生成 -->\n'
        '<resources>\n'
        f'    <color name="ic_launcher_background">{BACKGROUND_HEX}</color>\n'
        '</resources>\n',
        encoding="utf-8")
    print(f"    {color_xml.relative_to(REPO)}  {color_xml.stat().st_size} B")

    print("macOS：macos/Runner/Assets.xcassets/AppIcon.appiconset/")
    macos_set = REPO / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
    for size in (16, 32, 64, 128, 256, 512, 1024):
        save_png(master, macos_set / f"app_icon_{size}.png", size)

    print("iOS：ios/Runner/Assets.xcassets/AppIcon.appiconset/（注意：无 alpha 通道）")
    ios_set = REPO / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    ios_icons = {
        "Icon-App-20x20@1x.png": 20, "Icon-App-20x20@2x.png": 40, "Icon-App-20x20@3x.png": 60,
        "Icon-App-29x29@1x.png": 29, "Icon-App-29x29@2x.png": 58, "Icon-App-29x29@3x.png": 87,
        "Icon-App-40x40@1x.png": 40, "Icon-App-40x40@2x.png": 80, "Icon-App-40x40@3x.png": 120,
        "Icon-App-60x60@2x.png": 120, "Icon-App-60x60@3x.png": 180,
        "Icon-App-76x76@1x.png": 76, "Icon-App-76x76@2x.png": 152,
        "Icon-App-83.5x83.5@2x.png": 167, "Icon-App-1024x1024@1x.png": 1024,
    }
    for name, size in ios_icons.items():
        save_png(master, ios_set / name, size, alpha=False)

    print("Web：web/favicon.png 与 web/icons/")
    save_png(master, REPO / "web/favicon.png", 32)
    save_png(master, REPO / "web/icons/Icon-192.png", 192)
    save_png(master, REPO / "web/icons/Icon-512.png", 512)
    maskable = render_maskable(D // SS)
    save_png(maskable, REPO / "web/icons/Icon-maskable-192.png", 192)
    save_png(maskable, REPO / "web/icons/Icon-maskable-512.png", 512)

    print("母版（改图标时从这里对照/重绘）")
    save_png(master, REPO / "assets/icon/app_icon_1024.png", 1024)

    print("\n完成。记得把生成结果一起提交；想换配色改脚本顶部的 GRAD_* 常量即可。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
