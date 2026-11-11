import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Directory> localSourceDirectory() async {
  final base = Platform.isWindows
      ? await getApplicationSupportDirectory()
      : await getApplicationDocumentsDirectory();
  return Directory(path.join(base.path, 'local_sources'));
}

/// Desktop SQLite is stored separately from Android and server accounts.
Future<void> initializeLocalPlatform({String? databaseDirectory}) async {
  if (!Platform.isWindows && !Platform.isLinux) return;
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final folder =
      databaseDirectory ??
      path.join((await getApplicationSupportDirectory()).path, 'databases');
  await Directory(folder).create(recursive: true);
  await databaseFactory.setDatabasesPath(folder);
}
