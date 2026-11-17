#!/bin/bash
# QuantLens 打包脚本：把 SwiftPM 产物组装成可双击的 .app
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="QuantLens"
BUILD_DIR=".build/release"
APP_BUNDLE="dist/${APP_NAME}.app"
BUNDLE_ID="com.quantlens.app"
VERSION="1.0.0"

echo "▸ 编译 (release)…"
swift build -c release 2>&1 | grep -E "error|warning: .*unused" || true
if [ ! -f "${BUILD_DIR}/${APP_NAME}" ]; then
  echo "✗ 编译产物不存在"
  exit 1
fi

echo "▸ 组装 .app…"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# Info.plist
cat > "${APP_BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>QuantLens 量化看盘</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.finance</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
    <key>NSHumanReadableCopyright</key>
    <string>QuantLens · 本地量化分析工具</string>
</dict>
</plist>
PLIST

# PkgInfo
printf "APPL????" > "${APP_BUNDLE}/Contents/PkgInfo"

# 图标：用 SF Symbol 生成简易 icns
if [ ! -f "Resources/AppIcon.icns" ]; then
  echo "▸ 生成图标…"
  python3 - <<'PY'
import os, subprocess, tempfile
os.makedirs('Resources', exist_ok=True)
base = os.path.abspath('Resources')
iconset = os.path.join(base, 'AppIcon.iconset')
os.makedirs(iconset, exist_ok=True)

sizes = [16, 32, 64, 128, 256, 512, 1024]
svg_tpl = '''<svg xmlns="http://www.w3.org/2000/svg" width="{s}" height="{s}" viewBox="0 0 100 100">
<defs>
<linearGradient id="g" x1="0" y1="0" x2="0" y2="1">
<stop offset="0%" stop-color="#1b2740"/>
<stop offset="100%" stop-color="#0a0e16"/>
</linearGradient>
<linearGradient id="c1" x1="0" y1="0" x2="0" y2="1">
<stop offset="0%" stop-color="#f14a52"/>
<stop offset="100%" stop-color="#b8222a"/>
</linearGradient>
</defs>
<rect x="2" y="2" width="96" height="96" rx="22" fill="url(#g)"/>
<rect x="2" y="2" width="96" height="96" rx="22" fill="none" stroke="#3a4a66" stroke-width="1"/>
<g stroke="#f14a52" stroke-width="2.4" stroke-linecap="round">
<line x1="24" y1="30" x2="24" y2="52"/>
<line x1="24" y1="62" x2="24" y2="72"/>
<line x1="46" y1="22" x2="46" y2="40"/>
<line x1="46" y1="50" x2="46" y2="66"/>
<line x1="68" y1="34" x2="68" y2="48"/>
<line x1="68" y1="56" x2="68" y2="78"/>
</g>
<rect x="18" y="38" width="12" height="24" rx="1.5" fill="url(#c1)"/>
<rect x="40" y="30" width="12" height="20" rx="1.5" fill="#1ec78a"/>
<rect x="62" y="46" width="12" height="22" rx="1.5" fill="url(#c1)"/>
<path d="M16 84 L40 68 L56 76 L86 46" fill="none" stroke="#5a9eff" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/>
</svg>'''

files = []
for s in sizes:
    svg = tempfile.NamedTemporaryFile('w', suffix='.svg', delete=False)
    svg.write(svg_tpl.format(s=s))
    svg.close()
    if s <= 512:
        name = f'icon_{s}x{s}.png'
        out = os.path.join(iconset, name)
        subprocess.run(['/usr/bin/qlmanage', '-t', '-s', str(s), '-o', iconset, svg.name],
                       capture_output=True)
        # qlmanage 输出 <basename>.svg.png
        produced = os.path.join(iconset, os.path.basename(svg.name) + '.png')
        if os.path.exists(produced):
            os.replace(produced, out)
            files.append(out)
    if s == 512:
        # 512@2x
        out2 = os.path.join(iconset, 'icon_512x512@2x.png')
        subprocess.run(['/usr/bin/qlmanage', '-t', '-s', '1024', '-o', iconset, svg.name],
                       capture_output=True)
        produced = os.path.join(iconset, os.path.basename(svg.name) + '.png')
        if os.path.exists(produced):
            os.replace(produced, out2)
            files.append(out2)
    os.unlink(svg.name)

print('iconset files:', len(files))
PY
  iconutil -c icns "Resources/AppIcon.iconset" -o "Resources/AppIcon.icns" 2>&1 || echo "(图标生成跳过)"
  rm -rf "Resources/AppIcon.iconset"
fi

if [ -f "Resources/AppIcon.icns" ]; then
  cp "Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "${APP_BUNDLE}/Contents/Info.plist" 2>/dev/null || true
fi

echo "▸ 代码签名（ad-hoc）…"
codesign --force --deep --sign - "${APP_BUNDLE}" 2>&1 | grep -v "replacing existing signature" || true

echo "▸ 验证…"
codesign -dv "${APP_BUNDLE}" 2>&1 | head -5

echo "▸ 制作 DMG…"
DMG_STAGING="dist/dmg-staging"
DMG_FILE="dist/QuantLens.dmg"
rm -rf "${DMG_STAGING}" "${DMG_FILE}"
mkdir -p "${DMG_STAGING}"
cp -R "${APP_BUNDLE}" "${DMG_STAGING}/"
ln -s /Applications "${DMG_STAGING}/Applications"
hdiutil create -volname "QuantLens" -srcfolder "${DMG_STAGING}" -ov -format UDZO "${DMG_FILE}"
rm -rf "${DMG_STAGING}"

SIZE=$(du -sh "${DMG_FILE}" | cut -f1)
echo ""
echo "✓ 打包完成: ${DMG_FILE}  (${SIZE})"
echo "  双击挂载后把 QuantLens 拖到 Applications"
