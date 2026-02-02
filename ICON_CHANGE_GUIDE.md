# How to Change the GitVault App Icon

This guide explains how to update the app icon in a simple, step-by-step way.

## Quick Overview

Android has **two icon systems**:
- **Modern Android (8.0+)**: Uses adaptive icons (icon + background color)
- **Legacy Android**: Uses simple icon files

You need to update **both** for the icon to display correctly on all devices.

---

## Step 1: Prepare Your Icon Image

1. Create or export your icon as a **PNG or JPEG image**
2. Recommended size: **192×192 pixels** (or larger)
3. Save it to: `assets/icon/` folder

Example: `assets/icon/my-new-icon.png`

---

## Step 2: Update the Icon Files (Easy Way)

### Option A: Using Python Script (Recommended)

Run this Python script in the project root directory:

```python
from PIL import Image

# Change this to your icon file path
icon_path = 'assets/icon/my-new-icon.png'

# Load the icon
img = Image.open(icon_path).convert('RGBA')

# Android icon sizes
sizes = {
    'mdpi': (48, 48),
    'hdpi': (72, 72),
    'xhdpi': (96, 96),
    'xxhdpi': (144, 144),
    'xxxhdpi': (192, 192),
}

# Update BOTH modern (drawable) and legacy (mipmap) icons
base_path = 'android/app/src/main/res'

for density, size in sizes.items():
    resized = img.resize(size, Image.Resampling.LANCZOS)

    # Modern Android 8.0+ (adaptive icons)
    drawable_path = f'{base_path}/drawable-{density}/ic_launcher_foreground.png'
    resized.save(drawable_path, 'PNG')
    print(f'Updated: {drawable_path}')

    # Legacy Android (fallback)
    mipmap_path = f'{base_path}/mipmap-{density}/ic_launcher.png'
    resized.save(mipmap_path, 'PNG')
    print(f'Updated: {mipmap_path}')

print('✓ All icon files updated!')
```

### Option B: Manual Update (If Python not available)

Manually copy and resize your icon to these locations using an image editor:

**Modern icons** (Android 8.0+):
- `android/app/src/main/res/drawable-mdpi/ic_launcher_foreground.png` (48×48)
- `android/app/src/main/res/drawable-hdpi/ic_launcher_foreground.png` (72×72)
- `android/app/src/main/res/drawable-xhdpi/ic_launcher_foreground.png` (96×96)
- `android/app/src/main/res/drawable-xxhdpi/ic_launcher_foreground.png` (144×144)
- `android/app/src/main/res/drawable-xxxhdpi/ic_launcher_foreground.png` (192×192)

**Legacy icons** (older Android):
- `android/app/src/main/res/mipmap-mdpi/ic_launcher.png` (48×48)
- `android/app/src/main/res/mipmap-hdpi/ic_launcher.png` (72×72)
- `android/app/src/main/res/mipmap-xhdpi/ic_launcher.png` (96×96)
- `android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png` (144×144)
- `android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png` (192×192)

---

## Step 3: Rebuild the App

Run in the `android/` directory:

```bash
./gradlew clean assembleRelease
```

The new APK will be created at:
```
build/app/outputs/apk/release/app-release.apk
```

---

## Step 4: Copy to Downloads

```bash
cp build/app/outputs/apk/release/app-release.apk ../Downloads/gitvault-latest.apk
```

---

## Step 5: Install on Device

1. Transfer the APK to your Android device
2. Open a file manager and tap the APK
3. Tap "Install"
4. Open the app - your new icon should appear! ✓

---

## Why Two Icon Systems?

| System | Android Version | File Location | Purpose |
|--------|-----------------|----------------|---------|
| **Adaptive Icons** | 8.0+ (API 26+) | `drawable-{density}/` | Modern icon with background color |
| **Legacy Icons** | 7.1 and below | `mipmap-{density}/` | Fallback for older devices |

Modern devices use **adaptive icons** only. Legacy icons are a fallback for older Android versions.

---

## Common Issues

### Icon doesn't update after rebuild
- Make sure you updated **BOTH** drawable AND mipmap files
- Clear app cache: `Settings > Apps > GitVault > Storage > Clear Cache`
- Uninstall and reinstall the app

### Icon looks distorted
- Ensure your source image is at least 192×192 pixels
- Use high-quality PNG with transparency (RGBA)
- Avoid heavy compression

### Icon appears cropped on some phones
- Adaptive icons crop to a 108×108 circle/shape
- Keep important content in the center
- Use 192×192 as the safe area

---

## Next Steps

After changing the icon, consider also updating:
- App name in `pubspec.yaml`
- App description in `pubspec.yaml`
- Version number: `version: 1.0.0+1`

Then rebuild and you're done! 🎉

---

## Questions?

Refer to the official Android documentation:
https://developer.android.com/guide/practices/ui_guidelines/icon_design_adaptive
