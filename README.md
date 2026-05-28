![Screenshot](https://boards.chance.surf/assets/promo.png)

# Chanawoo

**Chanawoo** is an unofficial fork of [Chance](https://github.com/moffatman/chan), the imageboard browser built with Flutter for iOS and Android.

This fork adds **[owo.vg](https://owo.vg)** posting integration, offline thread downloading (from [Lystus/chan](https://github.com/Lystus/chan)), and ships under a separate Android package ID so it can be installed **alongside** the official Chance app.

| | Official Chance | Chanawoo (this fork) |
|---|---|---|
| GitHub | [moffatman/chan](https://github.com/moffatman/chan) | [4cuck/4chan](https://github.com/4cuck/4chan) |
| Android package | `com.moffatman.chan` | `com.chanawoo.app` |
| App name | Chance | Chanawoo |
| owo.vg posting | — | Yes |
| Thread download / CopyParty / Kuroba import | — | Yes |

Upstream development continues on the original repository. Chanawoo tracks that codebase and layers fork-specific changes on top. Thread downloading and CopyParty sync are integrated from [Lystus/chan](https://github.com/Lystus/chan) (excluding cosmetic/theme changes).

## What's different in this fork

- **owo.vg integration** — post to 4chan through owo.vg (WebSocket posting, captcha UI, Gold Pass login, and related settings).
- **Thread downloading** — save full threads locally for offline reading, with progress tracking and archive detection.
- **CopyParty sync** — optional CopyParty server backend for downloaded thread media.
- **Kuroba import/export** — import threads from Kuroba backups; export and bulk-manage downloaded threads.
- **Hide/unhide images** — per-image hide filter by MD5.
- **Side-by-side install** — different package ID from Play Store / upstream Chance, so both apps can be installed at once.
- **Same gallery album and deep links as Chance** — saved images go to the **Chance** gallery album by default, and `chance://` deep links open in Chanawoo.
- **One-time app data migration** — on first launch, if Chanawoo has no settings yet and a co-installed `com.moffatman.chan` app exists with the **same signing key**, Hive data is copied automatically. Play Store Chance uses a different key, so migration works for fork / sideload builds only, not live sharing with the official app.

## Features

All core Chance features are included, plus fork-specific posting support:

- Multi-column layout for larger screens
- WEBM playback and conversion
- Pick images through in-app web search
- Media gallery view
- Save threads, posts, and attachments to a local collection
- Automatically aligns the captcha slider
- Gestures to navigate through replies
- Switch between multiple browsing tabs
- Optional and automatic adjustments for mouse usage
- Regular-expression filters to hide or highlight posts
- Support for archives to access deleted threads or search for posts
- Thread watcher to check for replies
- **owo.vg posting** for supported boards
- **Offline downloaded threads** with CopyParty and Kuroba support

## Installing on Android

APKs are published on the [fork releases page](https://github.com/4cuck/4chan/releases/).

Download the APK that matches your device:

- `app-arm64-v8a-release.apk` — most phones
- `app-armeabi-v7a-release.apk` — older 32-bit ARM devices
- `app-x86_64-release.apk` — emulators

If you previously installed Chanawoo v123 with empty data, clear Chanawoo app storage (or uninstall and reinstall) while a compatible `com.moffatman.chan` build is still installed, then launch Chanawoo again to trigger migration.

## Installing on iOS

Chanawoo releases are Android-focused. For iOS, use upstream [Chance beta testing](https://testflight.apple.com/join/gdHJSbzI) from the official project.

## How to compile

1. [Install Flutter](https://docs.flutter.dev/get-started/install)
2. Clone and enter this repository:
```
git clone https://github.com/4cuck/4chan.git
cd 4chan
```
3. Fetch dependencies:
```
flutter pub get
```
4. (Optional) Change the package name (find-and-replace `com.chanawoo.app` with your own identifier) if you want your own signing keys for distribution.
5. Run `build_runner` to generate required Dart code:
```
flutter pub run build_runner build
```
6. Build a release APK for Android:
```
flutter build apk --split-per-abi --release
```
7. To build for iOS (Mac and Xcode required):
```
flutter build ios --release
```
8. For development with a connected device:
```
flutter run
```

Chance upstream is developed on Flutter `master`; if you hit build errors, try `flutter channel dev` or `flutter channel master`.

## FAQ

### Why isn't it displaying the content I expect?

By default, the app is set up to browse a test server. In app settings, edit your content preferences to browse a different imageboard.

### Why are some settings on a web page?

To comply with [Apple App Store guidelines](https://developer.apple.com/app-store/review/guidelines/#user-generated-content), not all settings are modifiable in the app.

### How can I quickly scroll to the top of a thread?

Tap the status bar.

### How can I quickly scroll to the bottom of a thread?

Hold on the post counter at the bottom-right.

### How can I get help, report a bug, or request a feature?

For **Chanawoo / owo.vg issues**, open an issue on [4cuck/4chan](https://github.com/4cuck/4chan/issues).

For **upstream Chance** bugs and features, use the [moffatman/chan](https://github.com/moffatman/chan/issues) tracker or the meta imageboard linked from Chance settings.

## License

Based on [Chance](https://github.com/moffatman/chan), licensed under version 3 of the GNU General Public License. See [LICENSE](LICENSE) for more information.
