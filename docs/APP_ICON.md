# 应用图标

原图：`HermesMac/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png`。
包含 macOS 的 16、32、128、256、512 点及其 Retina 尺寸。

替换 1024 × 1024 原图后运行：

```sh
python3 script/generate_app_icon.py
python3 script/generate_project.py
./script/build_and_run.sh --verify
```

Xcode 在 Debug 和 Release 中编译 AppIcon，生成应用包中的
`Contents/Resources/AppIcon.icns`。Info.plist 声明此文件供 Finder 和系统通知使用；
应用启动时也将其设为 Dock 图标，侧栏使用同一图标。
本地启动脚本刷新此应用的 Launch Services 注册，避免沿用旧图标。

## 原图生成提示词

使用内置 imagegen 工具，透明背景：

> Use case: logo-brand. Create a production macOS application icon for Hermes, a desktop AI chat application. Single centered bold ivory H monogram subtly incorporating two small messenger wings into its upper strokes, immediately legible at 16px. Deep midnight teal rounded-square tile with restrained soft dimensional lighting, elegant polished native macOS icon. No words, no other symbols, no watermark, no mockup or device. Square 1024x1024 canvas, tile occupies approximately 84% of canvas width with macOS squircle corners, perfectly centered. Outside tile fully transparent, subtle drop shadow. Clean deliberate geometric silhouette, uncluttered.

蓝色主题版本继续使用内置 imagegen 编辑，提示词：

> Use case: precise-object-edit. Edit this Hermes macOS app icon. Change ONLY the deep teal tile color to a rich royal blue matching a blue macOS interface (#2878F0 accent, deeper cobalt shadows). Preserve the ivory winged H exactly, its geometry, all framing, tile shape, lighting, subtle shadow, transparency and resolution. No additional elements or words. Transparent background outside tile.
