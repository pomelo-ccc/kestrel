import '../window/app_windows.dart';
import '../workspace/workspace.dart';

abstract final class NotchDropzone {
  static void start({
    required Workspace workspace,
    required AppWindows windows,
  }) {}

  static void stop() {}
}
