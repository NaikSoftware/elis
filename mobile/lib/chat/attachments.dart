import 'package:file_picker/file_picker.dart';

import '../link/mux.dart';

const uploadMaxBytes = 20971520; // UploadLimits.maxBytes
const uploadMaxFiles = 10; // UploadLimits.maxFiles
const tooLarge = 'file too large (max 20 MiB)';
const tooMany = 'at most 10 files per message';

class PickedFile {
  const PickedFile({required this.name, required this.path, required this.size});
  final String name, path;
  final int size;
}

typedef PickFiles = Future<List<PickedFile>> Function();
typedef UploadFile = UploadChannel Function(PickedFile f);

/// The system picker, several files of any type; throws [UploadFailed] `cannot read <name>` for a file with no local copy.
Future<List<PickedFile>> pickFiles() async => [
      for (final f in await FilePicker.pickFiles(type: FileType.any))
        PickedFile(
            name: f.name,
            path: f.path ?? (throw UploadFailed('cannot read ${f.name}')),
            size: f.lengthSync() ?? await f.length() ?? (throw UploadFailed('cannot read ${f.name}'))),
    ];

/// The prompt line: [text] trimmed, then ` Attached: '<p1>' '<p2>'`; host names never hold a quote.
String attachedLine(String text, List<String> paths) {
  if (paths.isEmpty) return text;
  final attached = "Attached: ${paths.map((p) => "'$p'").join(' ')}";
  final t = text.trim();
  return t.isEmpty ? attached : '$t $attached';
}

/// `1.2 MB`, `4 KB`, `512 B`.
String humanSize(int bytes) => bytes < 1024
    ? '$bytes B'
    : bytes < 1024 * 1024
        ? '${(bytes / 1024).round()} KB'
        : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

/// Sessions whose relay or host is too old to take files; cleared whenever the link's mux changes, as
/// `ModePicks.tooOld` is.
class AttachBlocks {
  static final Set<String> tooOld = {};
}
