// ignore_for_file: avoid_print

import 'dart:io';
import 'package:code_assets/code_assets.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';
import 'package:logging/logging.dart';
import 'package:hooks/hooks.dart';

const String _prebuiltReleaseTag = 'classipod-native-v1.5.6';
const String _githubDownloadBaseUrl =
    'https://github.com/adeeteya/flutter_taglib/releases/download/$_prebuiltReleaseTag';

/// Android API level the published prebuilt binaries are linked against.
///
/// This matches the `flutter.minSdkVersion` of the example app the release
/// workflow builds. Apps with a lower `minSdk` must build from source: the
/// prebuilt libraries import libc symbols that older devices do not export
/// (`__register_atfork`, pulled in by `libc++_static`, is API 23), so
/// `dlopen()` would fail at runtime on those devices.
const int _prebuiltAndroidNdkApi = 24;

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) {
      return;
    }

    final targetOSStr = input.config.code.targetOS
        .toString()
        .split('.')
        .last
        .toLowerCase();
    if (!_isPlatformEnabled(targetOSStr)) {
      print(
        'flutter_taglib: Building for $targetOSStr is disabled via flutter_taglib.yaml. Skipping compilation.',
      );
      return;
    }

    final buildDesktopFromSource = _shouldBuildDesktopFromSource();
    if ((targetOSStr == 'windows' || targetOSStr == 'linux') &&
        !buildDesktopFromSource) {
      final archStr = input.config.code.targetArchitecture
          .toString()
          .split('.')
          .last
          .toLowerCase();
      if (archStr == 'x64') {
        await _bundlePrebuiltBinary(
          input: input,
          output: output,
          remoteFileName: targetOSStr == 'windows'
              ? 'flutter_taglib_windows_x64.dll'
              : 'libflutter_taglib_linux_x64.so',
          localFileName: targetOSStr == 'windows'
              ? 'flutter_taglib_native.dll'
              : 'libflutter_taglib_native.so',
          targetOS: targetOSStr,
          arch: archStr,
        );
        return;
      } else {
        throw UnsupportedError(
          'flutter_taglib prebuilt binaries are only supported on x64 architecture. Please build from source for $archStr.',
        );
      }
    }

    final packageName = input.packageName;
    final nativeLibraryName = '${packageName}_native';

    final buildAndroidFromSource = _shouldBuildAndroidFromSource();
    if (targetOSStr == 'android' && !buildAndroidFromSource) {
      final archStr = input.config.code.targetArchitecture
          .toString()
          .split('.')
          .last
          .toLowerCase();
      final abi = _mapArchitectureToAndroidAbi(archStr);
      final targetNdkApi = input.config.code.android.targetNdkApi;
      if (abi == null || abi == 'x86') {
        print(
          'flutter_taglib: No prebuilt Android binary for architecture: $archStr ($abi). Falling back to source build.',
        );
      } else if (targetNdkApi < _prebuiltAndroidNdkApi) {
        // Building from source targets the app's own NDK API level, which
        // keeps the library loadable on the devices the app claims to support.
        print(
          'flutter_taglib: Prebuilt Android binaries need minSdk >= $_prebuiltAndroidNdkApi, '
          'but this app targets $targetNdkApi. Falling back to source build.',
        );
      } else {
        await _bundlePrebuiltBinary(
          input: input,
          output: output,
          remoteFileName: 'libflutter_taglib_android_$abi.so',
          localFileName: 'libflutter_taglib_native.so',
          targetOS: targetOSStr,
          arch: archStr,
        );
        return;
      }
    }

    // --- Online Fetch TagLib & utfcpp ---
    final taglibVersion = '2.3.1-c2';
    final utfcppVersion = '4.0.9';

    final cacheDir = Directory('.dart_tool/flutter_taglib');
    final taglibExtractedDir = Directory(
      '${cacheDir.path}/taglib-$taglibVersion',
    );
    final targetUtfcppDir = Directory(
      '${taglibExtractedDir.path}/3rdparty/utfcpp',
    );

    if (!taglibExtractedDir.existsSync() ||
        !File('${targetUtfcppDir.path}/source/utf8.h').existsSync()) {
      print(
        'flutter_taglib: TagLib 2.3 or utfcpp missing in cache. Downloading sources...',
      );
      cacheDir.createSync(recursive: true);

      // 1. Download TagLib 2.3
      final taglibZip = File('${cacheDir.path}/taglib.zip');
      final taglibUrl =
          '$_githubDownloadBaseUrl/taglib-$taglibVersion.zip';
      print('Downloading TagLib from $taglibUrl...');
      await _downloadFile(taglibUrl, taglibZip);

      // 2. Download utfcpp
      final utfcppZip = File('${cacheDir.path}/utfcpp.zip');
      final utfcppUrl =
          '$_githubDownloadBaseUrl/utfcpp-$utfcppVersion.zip';
      print('Downloading utfcpp from $utfcppUrl...');
      await _downloadFile(utfcppUrl, utfcppZip);

      // 3. Extract TagLib
      print('Extracting TagLib...');
      await _extractZip(taglibZip, cacheDir);

      // 4. Extract utfcpp
      print('Extracting utfcpp...');
      await _extractZip(utfcppZip, cacheDir);

      // 5. Setup utfcpp dependency inside taglib-2.3/3rdparty/utfcpp
      print('Setting up utfcpp dependency...');
      if (targetUtfcppDir.existsSync()) {
        targetUtfcppDir.deleteSync(recursive: true);
      }
      targetUtfcppDir.createSync(recursive: true);

      final utfcppExtractedDir = Directory(
        '${cacheDir.path}/utfcpp-$utfcppVersion',
      );
      if (utfcppExtractedDir.existsSync()) {
        await _moveDirectory(utfcppExtractedDir, targetUtfcppDir);
        utfcppExtractedDir.deleteSync(recursive: true);
      }

      // Cleanup ZIPs
      if (taglibZip.existsSync()) taglibZip.deleteSync();
      if (utfcppZip.existsSync()) utfcppZip.deleteSync();
      print('flutter_taglib: Online sources fetched successfully.');
    }

    final sources = <String>['src/flutter_taglib.cpp'];

    final includes = <String>[
      'src',
      taglibExtractedDir.path,
      '${taglibExtractedDir.path}/taglib',
      '${taglibExtractedDir.path}/3rdparty/utfcpp/source',
    ];

    // TagLib headers often use sibling-relative includes such as `tfile.h`
    // or `oggfile.h`. On non-Windows desktop builds we can safely include all
    // TagLib subdirectories to satisfy those transitive includes.
    if (targetOSStr != 'windows') {
      final discoveredIncludeDirs = <String>{};
      final taglibRoot = Directory('${taglibExtractedDir.path}/taglib');
      if (taglibRoot.existsSync()) {
        for (final entity in taglibRoot.listSync(recursive: true)) {
          if (entity is File &&
              (entity.path.endsWith('.h') || entity.path.endsWith('.hpp'))) {
            discoveredIncludeDirs.add(entity.parent.path);
          }
        }
      }
      final sortedIncludeDirs = discoveredIncludeDirs.toList()..sort();
      includes.addAll(sortedIncludeDirs);
    }

    if (targetOSStr == 'windows') {
      final flattenedIncludeDir = Directory(
        '${cacheDir.path}/taglib_flattened_headers',
      );
      _prepareFlattenedWindowsHeaders(
        taglibRoot: Directory('${taglibExtractedDir.path}/taglib'),
        flattenedIncludeDir: flattenedIncludeDir,
      );
      includes.add(flattenedIncludeDir.path);
    }

    // Find all .cpp files in taglib/taglib recursively and group them by
    // subdirectory. We intentionally keep the include list short on Windows
    // because adding every subdirectory can push cl.exe over the command line
    // limit in CI.
    final taglibSubDir = Directory('${taglibExtractedDir.path}/taglib');
    final List<String> taglibLibraries = [];

    if (targetOSStr == 'windows') {
      final dirToCppFiles = <String, List<String>>{};
      if (taglibSubDir.existsSync()) {
        for (final entity in taglibSubDir.listSync(recursive: true)) {
          if (entity is File && entity.path.endsWith('.cpp')) {
            final parentDir = entity.parent.path;
            dirToCppFiles.putIfAbsent(parentDir, () => []).add(entity.path);
          }
        }
      }

      // Compile each directory's C++ files into small static libraries so the
      // generated cl.exe command line stays below Windows limits.
      for (final entry in dirToCppFiles.entries) {
        final dirPath = entry.key;
        final cppFiles = [...entry.value]..sort();

        final normalizedPath = dirPath.replaceAll('\\', '/');
        final pathParts = normalizedPath.split('/');
        final taglibIndex = pathParts.indexOf('taglib');
        String suffix;
        if (taglibIndex != -1 && taglibIndex < pathParts.length - 1) {
          suffix = pathParts.sublist(taglibIndex + 1).join('_');
        } else {
          suffix = pathParts.last;
        }
        if (suffix.isEmpty) {
          suffix = 'root';
        }

        final batches = _chunkFiles(cppFiles, 4);
        for (var index = 0; index < batches.length; index++) {
          final libName = 'taglib_${suffix}_$index';
          taglibLibraries.add(libName);

          // Clean up any existing .obj files in the output directory
          // to prevent them from being packaged into the static library.
          final outDirFile = Directory(input.outputDirectory.toFilePath());
          if (outDirFile.existsSync()) {
            for (final file in outDirFile.listSync()) {
              if (file is File && file.path.endsWith('.obj')) {
                try {
                  file.deleteSync();
                } catch (_) {}
              }
            }
          }

          final staticBuilder = CBuilder.library(
            name: libName,
            assetName: null, // Do not expose as native asset to Flutter
            sources: batches[index],
            includes: includes,
            defines: {'HAVE_CONFIG_H': '1', 'TAGLIB_STATIC': '1'},
            std: 'c++17',
            language: Language.cpp,
            linkModePreference: LinkModePreference.static,
          );

          await staticBuilder.run(
            input: input,
            output: output,
            logger: Logger('')
              ..level = Level.ALL
              ..onRecord.listen((record) => print(record.message)),
          );
        }
      }
    } else {
      // For other platforms, compile all .cpp files directly
      if (taglibSubDir.existsSync()) {
        for (final entity in taglibSubDir.listSync(recursive: true)) {
          if (entity is File && entity.path.endsWith('.cpp')) {
            sources.add(entity.path);
          }
        }
      }
    }

    final cbuilder = CBuilder.library(
      // Avoid colliding with the CocoaPods plugin framework name on iOS/macOS.
      // The asset id still points at the generated Dart bindings, but the
      // produced dynamic library/framework gets its own distinct basename.
      name: nativeLibraryName,
      assetName: '${packageName}_bindings_generated.dart',
      sources: sources,
      includes: includes,
      defines: {'HAVE_CONFIG_H': '1', 'TAGLIB_STATIC': '1'},
      std: 'c++17',
      language: Language.cpp,
      cppLinkStdLib: input.config.code.targetOS.toString().contains('android')
          ? 'c++_static'
          : null,
      flags: [
        if (!input.config.code.targetOS.toString().contains('windows'))
          '-fvisibility=hidden',
      ],
      libraries: [
        if (targetOSStr == 'windows') ...taglibLibraries,
        if (input.config.code.targetOS.toString().contains('android') ||
            input.config.code.targetOS.toString().contains('linux'))
          'm',
        if (input.config.code.targetOS.toString().contains('android')) 'log',
      ],
      libraryDirectories: [if (targetOSStr == 'windows') '.'],
    );

    await cbuilder.run(
      input: input,
      output: output,
      logger: Logger('')
        ..level = Level.ALL
        ..onRecord.listen((record) => print(record.message)),
    );
  });
}

/// Downloads (and caches) the prebuilt binary for [targetOS]/[arch] and bundles
/// it as this package's code asset.
///
/// The cache directory is keyed by release tag *and* target. A fat Android
/// build runs this hook once per ABI against the same package root, so a shared
/// cache path would hand every ABI whichever binary was downloaded first --
/// shipping e.g. the arm64 library inside `lib/armeabi-v7a/`, where `dlopen()`
/// then fails. Keying by tag also stops a `_prebuiltReleaseTag` bump from
/// silently reusing the previous release's binaries.
Future<void> _bundlePrebuiltBinary({
  required BuildInput input,
  required BuildOutputBuilder output,
  required String remoteFileName,
  required String localFileName,
  required String targetOS,
  required String arch,
}) async {
  final cacheDir = Directory.fromUri(
    input.packageRoot.resolve(
      '.dart_tool/flutter_taglib/prebuilt/$_prebuiltReleaseTag/$targetOS/$arch/',
    ),
  );
  if (!cacheDir.existsSync()) {
    cacheDir.createSync(recursive: true);
  }

  final prebuiltFile = File.fromUri(cacheDir.uri.resolve(localFileName));
  if (!prebuiltFile.existsSync()) {
    final url = '$_githubDownloadBaseUrl/$remoteFileName';
    print('flutter_taglib: Downloading prebuilt binary from $url...');
    await _downloadFile(url, prebuiltFile);
  } else {
    print(
      'flutter_taglib: Using cached prebuilt binary at ${prebuiltFile.path}',
    );
  }

  _verifyBinaryArchitecture(prebuiltFile, targetOS: targetOS, arch: arch);

  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: '${input.packageName}_bindings_generated.dart',
      linkMode: DynamicLoadingBundled(),
      file: prebuiltFile.uri,
    ),
  );
  print('flutter_taglib: Bundled prebuilt binary for $targetOS $arch');
}

/// Throws if [file] is not a native binary for [arch].
///
/// Cheap insurance against shipping a library that cannot be loaded: a stale
/// cache entry, a mismatched release asset, or an error page saved by a proxy
/// all fail the build here instead of at `dlopen()` time on a user's device.
void _verifyBinaryArchitecture(
  File file, {
  required String targetOS,
  required String arch,
}) {
  final length = file.lengthSync();
  if (length < 1024) {
    file.deleteSync();
    throw StateError(
      'flutter_taglib: prebuilt binary for $targetOS $arch is only $length '
      'bytes; the download was truncated. Removed it, please re-run the build.',
    );
  }

  final raf = file.openSync();
  int? actual;
  int? expected;
  try {
    final header = raf.readSync(0x40);
    final isElf =
        header.length >= 20 &&
        header[0] == 0x7F &&
        header[1] == 0x45 &&
        header[2] == 0x4C &&
        header[3] == 0x46;
    final isPe =
        header.length >= 0x40 && header[0] == 0x4D && header[1] == 0x5A;
    if (isElf) {
      actual = header[18] | (header[19] << 8);
      expected = _expectedElfMachine(arch);
    } else if (isPe) {
      final peOffset =
          header[0x3C] |
          (header[0x3D] << 8) |
          (header[0x3E] << 16) |
          (header[0x3F] << 24);
      raf.setPositionSync(peOffset + 4);
      final machine = raf.readSync(2);
      if (machine.length == 2) {
        actual = machine[0] | (machine[1] << 8);
        expected = _expectedPeMachine(arch);
      }
    }
  } finally {
    raf.closeSync();
  }

  if (expected != null && actual != expected) {
    file.deleteSync();
    throw StateError(
      'flutter_taglib: cached binary at ${file.path} is not built for $arch '
      '(machine 0x${actual!.toRadixString(16)}, expected '
      '0x${expected.toRadixString(16)}). Removed it, please re-run the build.',
    );
  }
}

/// ELF `e_machine` value expected for a Dart target architecture.
int? _expectedElfMachine(String arch) {
  switch (arch) {
    case 'arm':
      return 0x28; // EM_ARM
    case 'arm64':
      return 0xB7; // EM_AARCH64
    case 'ia32':
    case 'x86':
      return 0x03; // EM_386
    case 'x64':
      return 0x3E; // EM_X86_64
    case 'riscv32':
    case 'riscv64':
      return 0xF3; // EM_RISCV
    default:
      return null;
  }
}

/// PE `Machine` value expected for a Dart target architecture.
int? _expectedPeMachine(String arch) {
  switch (arch) {
    case 'arm64':
      return 0xAA64;
    case 'ia32':
    case 'x86':
      return 0x014C;
    case 'x64':
      return 0x8664;
    default:
      return null;
  }
}

void _prepareFlattenedWindowsHeaders({
  required Directory taglibRoot,
  required Directory flattenedIncludeDir,
}) {
  if (!taglibRoot.existsSync()) {
    return;
  }

  if (flattenedIncludeDir.existsSync()) {
    flattenedIncludeDir.deleteSync(recursive: true);
  }
  flattenedIncludeDir.createSync(recursive: true);

  final seenHeaderNames = <String, String>{};
  const allowedExtensions = <String>{'.h', '.hpp', '.tcc', '.inl', '.inc'};

  for (final entity in taglibRoot.listSync(recursive: true)) {
    if (entity is! File) continue;
    final extension = _extensionOf(entity.path).toLowerCase();
    if (!allowedExtensions.contains(extension)) continue;

    final headerName = entity.uri.pathSegments.last;
    final existingPath = seenHeaderNames[headerName];
    if (existingPath != null && existingPath != entity.path) {
      throw StateError(
        'Duplicate TagLib header name detected for Windows flattened includes: '
        '$headerName\n- $existingPath\n- ${entity.path}',
      );
    }
    seenHeaderNames[headerName] = entity.path;

    final targetFile = File('${flattenedIncludeDir.path}/$headerName');
    entity.copySync(targetFile.path);
  }
}

String _extensionOf(String filePath) {
  final slashIndex = filePath.lastIndexOf(RegExp(r'[\\/]'));
  final fileName = slashIndex == -1
      ? filePath
      : filePath.substring(slashIndex + 1);
  final dotIndex = fileName.lastIndexOf('.');
  if (dotIndex <= 0 || dotIndex == fileName.length - 1) {
    return '';
  }
  return fileName.substring(dotIndex);
}

bool _shouldBuildDesktopFromSource() {
  if (Platform.environment['FLUTTER_TAGLIB_BUILD_DESKTOP_FROM_SOURCE'] ==
      'true') {
    return true;
  }

  const markerName = '.flutter_taglib_build_desktop_from_source';
  final markerPaths = [
    Directory.current.uri.resolve(markerName).toFilePath(),
    if (Directory.current.parent.existsSync())
      Directory.current.parent.uri.resolve(markerName).toFilePath(),
    if (Directory.current.parent.existsSync() &&
        Directory.current.parent.parent.existsSync())
      Directory.current.parent.parent.uri.resolve(markerName).toFilePath(),
  ];

  for (final path in markerPaths) {
    if (File(path).existsSync()) {
      return true;
    }
  }

  return false;
}

bool _shouldBuildAndroidFromSource() {
  if (Platform.environment['FLUTTER_TAGLIB_BUILD_ANDROID_FROM_SOURCE'] ==
      'true') {
    return true;
  }

  const markerName = '.flutter_taglib_build_android_from_source';
  final markerPaths = [
    Directory.current.uri.resolve(markerName).toFilePath(),
    if (Directory.current.parent.existsSync())
      Directory.current.parent.uri.resolve(markerName).toFilePath(),
    if (Directory.current.parent.existsSync() &&
        Directory.current.parent.parent.existsSync())
      Directory.current.parent.parent.uri.resolve(markerName).toFilePath(),
  ];

  for (final path in markerPaths) {
    if (File(path).existsSync()) {
      return true;
    }
  }

  return false;
}

String? _mapArchitectureToAndroidAbi(String archStr) {
  switch (archStr) {
    case 'arm64':
      return 'arm64-v8a';
    case 'arm':
      return 'armeabi-v7a';
    case 'x64':
      return 'x86_64';
    case 'ia32':
    case 'x86':
      return 'x86';
    default:
      return null;
  }
}

Future<void> _downloadFile(String url, File targetFile) async {
  final client = HttpClient();
  final partialFile = File('${targetFile.path}.$pid.part');
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != 200) {
      throw Exception('Failed to download from $url: ${response.statusCode}');
    }
    final bytes = await response.fold<List<int>>([], (p, e) => p..addAll(e));
    await partialFile.writeAsBytes(bytes);
    if (targetFile.existsSync()) {
      targetFile.deleteSync();
    }
    partialFile.renameSync(targetFile.path);
  } catch (_) {
    if (partialFile.existsSync()) {
      partialFile.deleteSync();
    }
    rethrow;
  } finally {
    client.close();
  }
}

Future<void> _extractZip(File zipFile, Directory destDir) async {
  ProcessResult result;
  if (Platform.isWindows) {
    result = await Process.run('tar', [
      '-xf',
      zipFile.path,
      '-C',
      destDir.path,
    ]);
  } else {
    result = await Process.run('unzip', [
      '-o',
      '-q',
      zipFile.path,
      '-d',
      destDir.path,
    ]);
  }
  if (result.exitCode != 0) {
    throw Exception('Failed to extract ${zipFile.path}: ${result.stderr}');
  }
}

Future<void> _moveDirectory(Directory source, Directory destination) async {
  for (final entity in source.listSync()) {
    final name = entity.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
    if (entity is File) {
      entity.renameSync('${destination.path}/$name');
    } else if (entity is Directory) {
      final newDir = Directory('${destination.path}/$name');
      newDir.createSync(recursive: true);
      await _moveDirectory(entity, newDir);
    }
  }
}

List<List<String>> _chunkFiles(List<String> files, int chunkSize) {
  final chunks = <List<String>>[];
  for (var start = 0; start < files.length; start += chunkSize) {
    final end = start + chunkSize > files.length
        ? files.length
        : start + chunkSize;
    chunks.add(files.sublist(start, end));
  }
  return chunks;
}

bool _isPlatformEnabled(String targetOS) {
  // Check for configuration file in current directory or parent directory
  File? configFile;
  final pathsToCheck = [
    Directory.current.uri.resolve('flutter_taglib.yaml').toFilePath(),
    if (Directory.current.parent.existsSync())
      Directory.current.parent.uri.resolve('flutter_taglib.yaml').toFilePath(),
    if (Directory.current.parent.existsSync() &&
        Directory.current.parent.parent.existsSync())
      Directory.current.parent.parent.uri
          .resolve('flutter_taglib.yaml')
          .toFilePath(),
  ];

  for (final path in pathsToCheck) {
    final file = File(path);
    if (file.existsSync()) {
      configFile = file;
      break;
    }
  }

  if (configFile == null) {
    return true; // Default to enabled if no config file is found
  }

  try {
    final lines = configFile.readAsLinesSync();
    bool inPlatformsBlock = false;
    for (var line in lines) {
      line = line.trim();
      if (line.isEmpty || line.startsWith('#')) continue;

      if (line.startsWith('platforms:')) {
        inPlatformsBlock = true;
        continue;
      }

      // If we hit another top-level key, exit the platforms block
      if (inPlatformsBlock && line.endsWith(':') && !line.startsWith(' ')) {
        inPlatformsBlock = false;
      }

      if (inPlatformsBlock) {
        final parts = line.split(':');
        if (parts.length == 2) {
          final key = parts[0].trim().toLowerCase();
          final val = parts[1].trim().toLowerCase();
          if (key == targetOS.toLowerCase()) {
            return val == 'true';
          }
        }
      }
    }
  } catch (e) {
    print(
      'flutter_taglib hook/build.dart: error reading/parsing flutter_taglib.yaml: $e',
    );
  }

  return true; // Default to enabled on error or if not found in config
}
