import 'package:flutter/foundation.dart';

import '../window/app_windows.dart';
import '../workspace/workspace.dart';

abstract final class NotchDropzone {
  static final ValueNotifier<bool> pipEnabled = ValueNotifier<bool>(false);
  static final ValueNotifier<bool> islandEnabled = ValueNotifier<bool>(true);

  static void start({
    required Workspace workspace,
    required AppWindows windows,
  }) {}

  static void stop() {}
}
