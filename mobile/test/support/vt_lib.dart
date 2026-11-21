import 'dart:io';

/// The host libvtshim `tool/build-vtshim.sh` builds for the Dart tests.
final hostVtLib = 'build/vtshim/libvtshim.${Platform.isMacOS ? 'dylib' : 'so'}';
