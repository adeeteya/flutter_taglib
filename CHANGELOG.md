## Unreleased

- Base the ClassiPod fork on commit 1f69a6a80957a9f0fce52f82633cc8ba597ba3b1.
- Support built-in Kotlin without applying the legacy Kotlin Android plugin.
- Require Flutter 3.44 / Dart 3.12; the built-in Kotlin example requires Flutter 3.47.
- Host the pinned native binaries and TagLib/utfcpp source archives in this fork.

## 1.5.7
* fix(android): `UnsupportedError` on `armeabi-v7a` devices
* fix(android): apps with `minSdk` below 24 now build from source, since the published binaries import libc symbols older devices do not export

## 1.5.5
* core: improve tags extraction for wma/asf formats

## 1.5.4
* feat: add `TagLibFile.bitsPerSample`

## 1.5.3
* core: improve format names for matroska container

## 1.5.2
* fix: cover not extracted from mp4 in rare cases

## 1.5.1
* fix(android): remove dangerous JNI FindClass call in C++ taglib_bridge_open

## 1.5.0
* Supports TagLib AudioPropertiesStyle settings
* Added batch read functionality and multi-isolate support
* Metadata read performance optimization
* Support physical path SAF URI resolution and FD fallback
* Added performance benchmark test to the example

## 1.4.2
* Added `TagLibFile.format` to detect audio file formats (e.g. MP3, FLAC).
* Added `TagLibFile.isLossless` to check if an audio file is lossless.
* Improved `TagLibFile.coverData` for extracting cover art bytes.
* Updated prebuilt native binary download URLs.

## 1.4.1
* Eliminate analyze info prompt

## 1.4.0
* Song duration accurate to milliseconds.
* Deprecated unsupported interfaces.
* Android uses online pre-built artifacts

## 1.3.3
* Lower the Dart SDK requirements to 3.11.0

## 1.3.2
* Remove redundant logs
* Fixes the issue of Windows and Linux dynamic libraries not being downloaded during the build process.

## 1.3.1
* Update readme

## 1.3.0
* Using pre-built artifacts for taglibs in Windows, Linux, and Android
* Fixing Android permission issues

## 1.2.0
* Supports Android content://media format links

## 1.1.1
* Update document

## 1.1.0
* Support PropertyMap

## 1.0.3
* Support SPM

## 1.0.2
* Upgrade dependencies

## 1.0.1
* Adapted to pub.dev

## 1.0.0

* Initial release of flutter_taglib.
