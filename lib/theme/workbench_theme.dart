/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See packages/bao_editor/lib/monaco/LICENSE.txt for license information.
 *--------------------------------------------------------------------------------------------*/
// The workbench's color theme (`workbench.colorTheme`): which bundled VS Code
// theme is current, its colors as widgets read them, and keeping the choice.
//
// Adapted from VS Code 6a598d4a13031703d483d103c1d934a36ad27971:
// src/vs/workbench/services/themes/browser/workbenchThemeService.ts (the
// constructor's restore from storage, `setColorTheme`, `applyTheme`,
// `restoreColorTheme`) and common/workbenchThemeService.ts
// (`ThemeSettingDefaults`, `COLOR_THEME_*_INITIAL_COLORS`,
// `migrateThemeSettingsId`). The themes are the ones bundled under
// packages/bao_editor/assets/textmate (textmate_manifest.dart).

import 'dart:async';
import 'dart:convert' show JsonEncoder, jsonEncode;
import 'dart:io' show Directory, File;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:bao_editor/monaco/vs/base/common/color.dart' as vs;
import 'package:bao_editor/monaco/vs/base/common/json.dart' as vs_json;
import 'package:bao_editor/monaco/vs/platform/theme/common/color_utils.dart';
import 'package:bao_editor/monaco/vs/platform/theme/common/theme.dart';
import 'package:bao_editor/monaco/vs/workbench/services/themes/common/color_theme_data.dart';
import 'package:bao_editor/monaco/vs/workbench/services/themes/common/workbench_theme_service.dart'
    show IThemeExtensionPoint;
import 'package:path/path.dart' as p;
import 'package:bao_editor/textmate/textmate_manifest.dart';
import 'package:bao_editor/textmate/textmate_syntax.dart'
    show TextMateThemeSource;
import 'package:bao_editor/textmate/textmate_worker.dart'
    show decodeTextMateResource;

import '../ide/ide_color_theme_picker.dart';
import '../platform/event_log.dart';
import 'workbench_theme_initial_colors.dart';

export 'package:bao_editor/monaco/vs/platform/theme/common/theme.dart'
    show
        ColorScheme,
        ThemeTypeSelector,
        getThemeTypeSelector,
        isDark,
        isHighContrast;

/// `ThemeSettingDefaults`: the default theme of each color scheme. Ours are
/// Bao Dark and Bao Light, not upstream's Dark 2026 and Light 2026.
abstract final class ThemeSettingDefaults {
  static const colorThemeDark = 'Bao Dark';
  static const colorThemeLight = 'Bao Light';
  static const colorThemeHcDark = 'Default High Contrast';
  static const colorThemeHcLight = 'Default High Contrast Light';
}

/// `migrateThemeSettingsId`: the current id of a theme once named
/// [settingsId]. Themes no longer bundled (our former defaults among them)
/// give way to the Bao theme of their color scheme.
String migrateThemeSettingsId(String settingsId) => switch (settingsId) {
  'Default Dark Modern' => 'Dark Modern',
  'Default Light Modern' => 'Light Modern',
  'Default Dark+' => 'Dark+',
  'Default Light+' => 'Light+',
  'Experimental Dark' ||
  'VS Code Dark' ||
  'Dark 2026' ||
  'Visual Studio Dark' ||
  'Monokai' ||
  'Abyss' => ThemeSettingDefaults.colorThemeDark,
  'Experimental Light' ||
  'VS Code Light' ||
  'Light 2026' ||
  'Quiet Light' => ThemeSettingDefaults.colorThemeLight,
  _ => settingsId,
};

/// Where the app keeps the theme between runs: the `workbench.colorTheme`
/// setting and the storage entry that restores it without reading the theme
/// file (`ColorThemeData.toStorage`).
abstract interface class ColorThemeStorage {
  String? get colorThemeSetting;
  String? get colorThemeData;

  /// Whether the theme follows the system's appearance (Auto).
  bool get autoDetectColorScheme;

  /// Keeps [setting], whether it follows the system, and [data] (the
  /// colors' cache); [cacheOnly], the cache alone. Throws where it could
  /// not.
  Future<void> storeColorTheme({
    required String setting,
    String? data,
    bool autoDetectColorScheme = false,
    bool cacheOnly = false,
  });
}

/// Metadata for a user-created custom color theme stored under
/// `<dataDir>/themes/`.
class CustomThemeRecord {
  const CustomThemeRecord({
    required this.id,
    required this.label,
    required this.uiTheme,
    required this.path,
    this.baseTheme,
  });

  final String id;
  final String label;

  /// `'vs'` for Light, `'vs-dark'` for Dark.
  final String uiTheme;

  /// Relative filename inside `<dataDir>/themes/`.
  final String path;
  final String? baseTheme;

  bool get dark => uiTheme != 'vs';

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'uiTheme': uiTheme,
    'path': path,
    if (baseTheme != null) 'baseTheme': baseTheme,
  };

  static CustomThemeRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final label = raw['label'];
    final uiTheme = raw['uiTheme'];
    final path = raw['path'];
    final baseTheme = raw['baseTheme'];
    if (id is! String ||
        id.isEmpty ||
        label is! String ||
        label.isEmpty ||
        path is! String ||
        path.isEmpty) {
      return null;
    }
    return CustomThemeRecord(
      id: id,
      label: label,
      uiTheme: uiTheme is String && uiTheme.isNotEmpty ? uiTheme : 'vs-dark',
      path: path,
      baseTheme: baseTheme is String ? baseTheme : null,
    );
  }
}

/// Persistent per-theme color overrides (`workbench.themeOverrides`), custom
/// user themes (`workbench.customThemes`), and deleted built-in themes
/// (`workbench.deletedThemes`).
abstract final class ThemePaletteOverrides {
  static const overridesKey = 'workbench.themeOverrides';
  static const customThemesKey = 'workbench.customThemes';
  static const deletedThemesKey = 'workbench.deletedThemes';

  static const slotBackground = 'background';
  static const slotSidebar = 'sidebar';
  static const slotCard = 'card';
  static const slotForeground = 'foreground';
  static const slotAccent = 'accent';
  static const slotInlineCode = 'inlineCode';

  static const allSlots = <String>[
    slotBackground,
    slotSidebar,
    slotCard,
    slotForeground,
    slotAccent,
    slotInlineCode,
  ];

  static const defaultLightBackground = ui.Color(0xFFFAF9F5);
  static const defaultLightSidebar = ui.Color(0xFFEFEEEA);
  static const defaultLightCard = ui.Color(0xFFFFFFFF);
  static const defaultLightForeground = ui.Color(0xFF282624);
  static const defaultLightAccent = ui.Color(0xFFCF795A);
  static const defaultLightInlineCode = ui.Color(0xFF9E2825);

  static const defaultDarkBackground = ui.Color(0xFF1D1C1A);
  static const defaultDarkSidebar = ui.Color(0xFF161514);
  static const defaultDarkCard = ui.Color(0xFF252421);
  static const defaultDarkForeground = ui.Color(0xFFE6E3DC);
  static const defaultDarkAccent = ui.Color(0xFFD47F60);
  static const defaultDarkInlineCode = ui.Color(0xFFE58C7D);

  static final ValueNotifier<int> _revision = ValueNotifier<int>(0);
  static Listenable get changes => _revision;

  /// `themeId -> { slot -> Color }`.
  static final Map<String, Map<String, ui.Color>> _overrides = {};
  static final Map<String, CustomThemeRecord> _customRecords = {};
  static final Set<String> _deletedThemes = {};

  static Future<void> Function(String key, Object? value)? _writer;
  static String? _dataDir;
  static bool _syncingFromSettings = false;

  static void _notify() {
    _revision.value++;
    WorkbenchThemeService.instance.invalidateColors();
  }

  /// Connects persistent settings and `<dataDir>/themes/` custom theme files.
  static void follow(
    Listenable settings, {
    required Object? Function(String key) read,
    required Future<void> Function(String key, Object? value) write,
    required String dataDir,
  }) {
    _writer = write;
    _dataDir = dataDir;
    void sync() {
      if (_syncingFromSettings) return;
      _loadOverridesFromRaw(read(overridesKey));
      _loadCustomRecordsFromRaw(read(customThemesKey));
      _loadDeletedFromRaw(read(deletedThemesKey));
      unawaited(
        WorkbenchThemeService.instance.syncUserThemes(
          records: _customRecords.values.toList(growable: false),
          deletedIds: Set<String>.of(_deletedThemes),
          dataDir: dataDir,
        ),
      );
      _notify();
    }

    sync();
    settings.addListener(sync);
  }

  static void _loadOverridesFromRaw(Object? raw) {
    _overrides.clear();
    if (raw is! Map) return;
    for (final entry in raw.entries) {
      final themeId = entry.key;
      final value = entry.value;
      if (themeId is! String || value is! Map) continue;
      final slots = <String, ui.Color>{};
      for (final slotEntry in value.entries) {
        final k = slotEntry.key;
        final v = slotEntry.value;
        if (k is String && v is String) {
          if (parseHex(v) case final parsed?) {
            slots[k] = parsed;
          }
        }
      }
      if (slots.isNotEmpty) {
        _overrides[themeId] = slots;
      }
    }
  }

  static void _loadCustomRecordsFromRaw(Object? raw) {
    _customRecords.clear();
    if (raw is! List) return;
    for (final item in raw) {
      if (CustomThemeRecord.fromJson(item) case final record?) {
        _customRecords[record.id] = record;
      }
    }
  }

  static void _loadDeletedFromRaw(Object? raw) {
    _deletedThemes.clear();
    if (raw is! List) return;
    for (final item in raw) {
      if (item is String &&
          item.isNotEmpty &&
          item != ThemeSettingDefaults.colorThemeLight &&
          item != ThemeSettingDefaults.colorThemeDark) {
        _deletedThemes.add(item);
      }
    }
  }

  static Map<String, Object?>? _serializeOverrides() {
    if (_overrides.isEmpty) return null;
    final out = <String, Object?>{};
    for (final MapEntry(key: themeId, value: slots) in _overrides.entries) {
      if (slots.isEmpty) continue;
      out[themeId] = {
        for (final MapEntry(:key, :value) in slots.entries) key: toHex(value),
      };
    }
    return out.isEmpty ? null : out;
  }

  static List<Object?>? _serializeCustomRecords() {
    if (_customRecords.isEmpty) return null;
    return [for (final r in _customRecords.values) r.toJson()];
  }

  static List<Object?>? _serializeDeleted() {
    if (_deletedThemes.isEmpty) return null;
    return _deletedThemes.toList()..sort();
  }

  static Future<void> _persistKey(String key, Object? value) async {
    final write = _writer;
    if (write == null) return;
    _syncingFromSettings = true;
    try {
      await write(key, value);
    } catch (error) {
      debugPrint('$key not persisted: $error');
    } finally {
      _syncingFromSettings = false;
    }
  }

  static ui.Color? slotColor(String themeId, String slot) =>
      _overrides[themeId]?[slot];

  static Map<String, ui.Color> overridesFor(String themeId) =>
      Map<String, ui.Color>.unmodifiable(_overrides[themeId] ?? const {});

  static bool hasCustomFor(String themeId) =>
      (_overrides[themeId]?.isNotEmpty ?? false);

  static bool isCustomTheme(String themeId) =>
      _customRecords.containsKey(themeId);

  static Set<String> get deletedThemes =>
      Set<String>.unmodifiable(_deletedThemes);

  static bool canDeleteTheme(
    String themeId, {
    required int sameSchemeCount,
  }) =>
      sameSchemeCount > 1 &&
      themeId != ThemeSettingDefaults.colorThemeLight &&
      themeId != ThemeSettingDefaults.colorThemeDark;

  static Future<void> setSlotColor(
    String themeId,
    String slot,
    ui.Color? color,
  ) async {
    if (color == null) {
      final slots = _overrides[themeId];
      slots?.remove(slot);
      if (slots != null && slots.isEmpty) _overrides.remove(themeId);
    } else {
      (_overrides[themeId] ??= {})[slot] = color;
    }
    _notify();
    await _persistKey(overridesKey, _serializeOverrides());
  }

  static Future<void> resetTheme(String themeId) async {
    if (_overrides.remove(themeId) == null) return;
    _notify();
    await _persistKey(overridesKey, _serializeOverrides());
  }

  /// Creates a brand-new standalone theme cloned from [baseThemeId] (baking in
  /// [baseThemeId]'s current color tweaks when [copyBaseOverrides] is true),
  /// saves it under `<dataDir>/themes/`, and selects it immediately.
  static Future<String> createCustomTheme({
    required String label,
    required bool dark,
    required String baseThemeId,
    bool copyBaseOverrides = true,
  }) async {
    final trimmed = label.trim().isEmpty
        ? (dark ? 'Custom Dark' : 'Custom Light')
        : label.trim();
    final service = WorkbenchThemeService.instance;
    final existingIds = {
      for (final t in service.colorThemes) t.id,
      ..._customRecords.keys,
    };
    var id = trimmed;
    var suffix = 2;
    while (existingIds.contains(id)) {
      id = '$trimmed ($suffix)';
      suffix++;
    }
    final displayLabel = id;
    final rawMap = await service.readStandaloneThemeMap(
      baseThemeId,
      dark: dark,
    );
    rawMap['name'] = displayLabel;
    rawMap['type'] = dark ? 'dark' : 'light';
    final colorsMap = <String, Object?>{
      if (rawMap['colors'] case final Map m)
        for (final e in m.entries) '${e.key}': e.value,
    };
    final bakedSlots = copyBaseOverrides
        ? Map<String, ui.Color>.of(_overrides[baseThemeId] ?? const {})
        : <String, ui.Color>{};
    if (bakedSlots.isNotEmpty) {
      applySlotsToColorMap(colorsMap, bakedSlots, dark: dark);
    }
    rawMap['colors'] = colorsMap;

    final slug =
        'custom-${DateTime.now().millisecondsSinceEpoch}-'
        '${id.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '')}';
    final fileName = '${slug.isEmpty ? 'theme' : slug}-color-theme.json';
    final dataDir = _dataDir;
    if (dataDir != null && dataDir.isNotEmpty) {
      final themesDir = Directory(p.join(dataDir, 'themes'));
      await themesDir.create(recursive: true);
      final file = File(p.join(themesDir.path, fileName));
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(rawMap),
      );
    }

    final record = CustomThemeRecord(
      id: id,
      label: displayLabel,
      uiTheme: dark ? 'vs-dark' : 'vs',
      path: fileName,
      baseTheme: baseThemeId,
    );
    _customRecords[id] = record;
    await _persistKey(customThemesKey, _serializeCustomRecords());
    await service.syncUserThemes(
      records: _customRecords.values.toList(growable: false),
      deletedIds: Set<String>.of(_deletedThemes),
      dataDir: dataDir,
      preloadedJson: dataDir == null || dataDir.isEmpty
          ? {fileName: rawMap}
          : null,
    );
    _notify();
    await service.setColorTheme(id);
    return id;
  }

  /// Renames an existing user-created custom theme.
  static Future<String> renameCustomTheme(
    String themeId,
    String newLabel,
  ) async {
    final record = _customRecords[themeId];
    final trimmed = newLabel.trim();
    if (record == null || trimmed.isEmpty || trimmed == record.label) {
      return themeId;
    }
    final service = WorkbenchThemeService.instance;
    final existingIds = {
      for (final t in service.colorThemes)
        if (t.id != themeId) t.id,
      for (final k in _customRecords.keys)
        if (k != themeId) k,
    };
    var nextId = trimmed;
    var suffix = 2;
    while (existingIds.contains(nextId)) {
      nextId = '$trimmed ($suffix)';
      suffix++;
    }
    final updated = CustomThemeRecord(
      id: nextId,
      label: nextId,
      uiTheme: record.uiTheme,
      path: record.path,
      baseTheme: record.baseTheme,
    );
    _customRecords.remove(themeId);
    _customRecords[nextId] = updated;
    if (_overrides.remove(themeId) case final moved?) {
      _overrides[nextId] = moved;
      await _persistKey(overridesKey, _serializeOverrides());
    }
    final dataDir = _dataDir;
    if (dataDir != null && dataDir.isNotEmpty) {
      final file = File(p.join(dataDir, 'themes', record.path));
      if (await file.exists()) {
        try {
          final parsed = vs_json.parse(await file.readAsString());
          if (parsed is Map) {
            final map = Map<String, Object?>.from(parsed);
            map['name'] = nextId;
            await file.writeAsString(
              const JsonEncoder.withIndent('  ').convert(map),
            );
          }
        } catch (error) {
          debugPrint('Custom theme rename file update skipped: $error');
        }
      }
    }
    await _persistKey(customThemesKey, _serializeCustomRecords());
    final wasActive =
        service.colorThemeId == themeId || service.colorThemeSetting == themeId;
    await service.syncUserThemes(
      records: _customRecords.values.toList(growable: false),
      deletedIds: Set<String>.of(_deletedThemes),
      dataDir: dataDir,
    );
    _notify();
    if (wasActive) {
      await service.setColorTheme(nextId);
    }
    return nextId;
  }

  /// Deletes a custom theme (removing its JSON file) or hides a built-in theme.
  static Future<void> deleteTheme(
    String themeId, {
    required bool dark,
  }) async {
    if (themeId == ThemeSettingDefaults.colorThemeLight ||
        themeId == ThemeSettingDefaults.colorThemeDark) {
      return;
    }
    final service = WorkbenchThemeService.instance;
    final wasActive =
        service.colorThemeId == themeId || service.colorThemeSetting == themeId;
    final custom = _customRecords.remove(themeId);
    _overrides.remove(themeId);
    if (custom != null) {
      final dataDir = _dataDir;
      if (dataDir != null && dataDir.isNotEmpty) {
        final file = File(p.join(dataDir, 'themes', custom.path));
        if (await file.exists()) {
          try {
            await file.delete();
          } catch (error) {
            debugPrint('Custom theme delete failed: $error');
          }
        }
      }
      await _persistKey(customThemesKey, _serializeCustomRecords());
    } else {
      _deletedThemes.add(themeId);
      await _persistKey(deletedThemesKey, _serializeDeleted());
    }
    await _persistKey(overridesKey, _serializeOverrides());
    await service.syncUserThemes(
      records: _customRecords.values.toList(growable: false),
      deletedIds: Set<String>.of(_deletedThemes),
      dataDir: _dataDir,
    );
    _notify();
    if (wasActive) {
      await service.setColorTheme(
        dark
            ? ThemeSettingDefaults.colorThemeDark
            : ThemeSettingDefaults.colorThemeLight,
      );
    }
  }

  /// Restores one or all previously deleted built-in themes.
  static Future<void> restoreDeletedThemes([String? specificId]) async {
    final changed = specificId == null
        ? _deletedThemes.isNotEmpty
        : _deletedThemes.remove(specificId);
    if (!changed) return;
    if (specificId == null) _deletedThemes.clear();
    await _persistKey(deletedThemesKey, _serializeDeleted());
    await WorkbenchThemeService.instance.syncUserThemes(
      records: _customRecords.values.toList(growable: false),
      deletedIds: Set<String>.of(_deletedThemes),
      dataDir: _dataDir,
    );
    _notify();
  }

  static String toHex(ui.Color color) {
    final rgb = color.toARGB32() & 0xFFFFFF;
    return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  static ui.Color? parseHex(String input) {
    final cleaned = input.trim().replaceFirst(RegExp(r'^#'), '');
    if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(cleaned)) return null;
    final value = int.tryParse(cleaned, radix: 16);
    return value == null ? null : ui.Color(0xFF000000 | value);
  }

  static ui.Color? resolveOverride(
    String id, {
    required String themeId,
    required bool dark,
  }) {
    final slots = _overrides[themeId];
    if (slots == null || slots.isEmpty) return null;
    final bg = slots[slotBackground];
    final sb = slots[slotSidebar];
    final card = slots[slotCard];
    final fg = slots[slotForeground];
    final accent = slots[slotAccent];
    final inlineCode = slots[slotInlineCode];

    if (inlineCode != null && id == 'textPreformat.foreground') {
      return inlineCode;
    }

    if (card != null) {
      switch (id) {
        case 'agentsChatInput.background' ||
            'chat.requestBubbleBackground' ||
            'list.activeSelectionBackground' ||
            'list.inactiveSelectionBackground' ||
            'list.focusBackground' ||
            'menu.background' ||
            'quickInput.background' ||
            'editorWidget.background' ||
            'editorSuggestWidget.background' ||
            'editorHoverWidget.background' ||
            'settings.dropdownBackground' ||
            'dropdown.background' ||
            'dropdown.listBackground' ||
            'input.background' ||
            'agentsNewSessionButton.background' ||
            'notifications.background':
          return card;
      }
    }

    if (sb != null) {
      switch (id) {
        case 'sideBar.background' ||
            'sideBarSectionHeader.background' ||
            'activityBar.background' ||
            'titleBar.activeBackground' ||
            'titleBar.inactiveBackground' ||
            'panel.background' ||
            'statusBar.background' ||
            'statusBar.inactiveBackground' ||
            'statusBar.noFolderBackground' ||
            'agents.background' ||
            'terminal.background' ||
            'editorGroupHeader.tabsBackground' ||
            'tab.inactiveBackground':
          return sb;
      }
    }

    if (bg != null) {
      switch (id) {
        case 'editor.background' ||
            'agentsPanel.background' ||
            'surface.background' ||
            'tab.activeBackground' ||
            'tab.hoverBackground' ||
            'breadcrumb.background' ||
            'editorGutter.background' ||
            'agentStatusIndicator.background' ||
            'agentsCard.background':
          return bg;
        case 'sideBar.background' ||
            'sideBarSectionHeader.background' ||
            'activityBar.background' ||
            'titleBar.activeBackground' ||
            'titleBar.inactiveBackground' ||
            'panel.background' ||
            'statusBar.background' ||
            'agents.background'
            when sb == null:
          final target =
              fg ?? (dark ? defaultDarkForeground : defaultLightForeground);
          return ui.Color.lerp(bg, target, 0.042);
        case 'textPreformat.background':
          final target =
              fg ?? (dark ? defaultDarkForeground : defaultLightForeground);
          return target.withValues(alpha: dark ? 0.11 : 0.055);
      }
    }

    if (bg != null || sb != null || fg != null) {
      switch (id) {
        case 'sideBar.border' ||
            'panel.border' ||
            'surface.border' ||
            'agentsPanel.border' ||
            'widget.border' ||
            'input.border' ||
            'dropdown.border' ||
            'menu.border' ||
            'agentsChatInput.border' ||
            'chat.requestBorder' ||
            'textSeparator.foreground':
          final baseBg =
              bg ??
              sb ??
              (dark ? defaultDarkBackground : defaultLightBackground);
          final baseFg =
              fg ?? (dark ? defaultDarkForeground : defaultLightForeground);
          return ui.Color.lerp(baseBg, baseFg, dark ? 0.14 : 0.10);
      }
    }

    if (fg != null) {
      switch (id) {
        case 'foreground' ||
            'editor.foreground' ||
            'sideBar.foreground' ||
            'settings.headerForeground' ||
            'agentsPanel.foreground' ||
            'surface.foreground' ||
            'agentsChatInput.foreground' ||
            'list.activeSelectionForeground' ||
            'list.inactiveSelectionForeground' ||
            'list.hoverForeground' ||
            'sideBarTitle.foreground' ||
            'titleBar.activeForeground' ||
            'input.foreground' ||
            'dropdown.foreground' ||
            'menu.foreground' ||
            'quickInput.foreground' ||
            'terminal.foreground':
          return fg;
        case 'descriptionForeground' ||
            'icon.foreground' ||
            'sideBarSectionHeader.foreground':
          final canvas =
              bg ?? (dark ? defaultDarkBackground : defaultLightBackground);
          return ui.Color.lerp(fg, canvas, 0.42);
        case 'disabledForeground' ||
            'input.placeholderForeground' ||
            'agentsChatInput.placeholderForeground':
          final canvas =
              bg ?? (dark ? defaultDarkBackground : defaultLightBackground);
          return ui.Color.lerp(fg, canvas, 0.60);
      }
    }

    if (accent != null) {
      switch (id) {
        case 'button.background' ||
            'textLink.foreground' ||
            'focusBorder' ||
            'badge.background' ||
            'activityBarBadge.background' ||
            'agentsBadge.background' ||
            'agentsUnreadBadge.background' ||
            'list.highlightForeground' ||
            'editorCursor.foreground' ||
            'sash.hoverBorder' ||
            'chat.inputWorkingBorderColor1' ||
            'progressBar.background':
          return accent;
        case 'button.hoverBackground' || 'textLink.activeForeground':
          return ui.Color.lerp(
            accent,
            dark ? const ui.Color(0xFFFFFFFF) : const ui.Color(0xFF000000),
            0.12,
          );
      }
    }
    return null;
  }

  /// Applies [slots] to a raw VS Code theme `colors` map for standalone export.
  static void applySlotsToColorMap(
    Map<String, Object?> colors,
    Map<String, ui.Color> slots, {
    required bool dark,
  }) {
    const targetIds = <String>[
      'editor.background',
      'agentsPanel.background',
      'surface.background',
      'tab.activeBackground',
      'tab.hoverBackground',
      'breadcrumb.background',
      'editorGutter.background',
      'agentStatusIndicator.background',
      'agentsCard.background',
      'sideBar.background',
      'sideBarSectionHeader.background',
      'activityBar.background',
      'titleBar.activeBackground',
      'titleBar.inactiveBackground',
      'panel.background',
      'statusBar.background',
      'statusBar.inactiveBackground',
      'statusBar.noFolderBackground',
      'agents.background',
      'terminal.background',
      'editorGroupHeader.tabsBackground',
      'tab.inactiveBackground',
      'agentsChatInput.background',
      'chat.requestBubbleBackground',
      'list.activeSelectionBackground',
      'list.inactiveSelectionBackground',
      'list.focusBackground',
      'menu.background',
      'quickInput.background',
      'editorWidget.background',
      'editorSuggestWidget.background',
      'editorHoverWidget.background',
      'settings.dropdownBackground',
      'dropdown.background',
      'dropdown.listBackground',
      'input.background',
      'agentsNewSessionButton.background',
      'notifications.background',
      'sideBar.border',
      'panel.border',
      'surface.border',
      'agentsPanel.border',
      'widget.border',
      'input.border',
      'dropdown.border',
      'menu.border',
      'agentsChatInput.border',
      'chat.requestBorder',
      'textSeparator.foreground',
      'foreground',
      'editor.foreground',
      'sideBar.foreground',
      'settings.headerForeground',
      'agentsPanel.foreground',
      'surface.foreground',
      'agentsChatInput.foreground',
      'list.activeSelectionForeground',
      'list.inactiveSelectionForeground',
      'list.hoverForeground',
      'sideBarTitle.foreground',
      'titleBar.activeForeground',
      'input.foreground',
      'dropdown.foreground',
      'menu.foreground',
      'quickInput.foreground',
      'terminal.foreground',
      'descriptionForeground',
      'icon.foreground',
      'sideBarSectionHeader.foreground',
      'disabledForeground',
      'input.placeholderForeground',
      'agentsChatInput.placeholderForeground',
      'button.background',
      'textLink.foreground',
      'focusBorder',
      'badge.background',
      'activityBarBadge.background',
      'agentsBadge.background',
      'agentsUnreadBadge.background',
      'list.highlightForeground',
      'editorCursor.foreground',
      'sash.hoverBorder',
      'chat.inputWorkingBorderColor1',
      'progressBar.background',
      'button.hoverBackground',
      'textLink.activeForeground',
      'textPreformat.foreground',
    ];
    const tempId = '__export__';
    _overrides[tempId] = Map<String, ui.Color>.of(slots);
    try {
      for (final key in targetIds) {
        final resolved = resolveOverride(key, themeId: tempId, dark: dark);
        if (resolved != null) {
          colors[key] = toHex(resolved);
        }
      }
    } finally {
      _overrides.remove(tempId);
    }
  }
}

/// A color theme's colors as widgets read them: what the theme sets, else
/// the color registry's default for its type (`IColorTheme.getColor`).
class WorkbenchColors {
  WorkbenchColors(this.theme, {String? themeId})
    : themeId = themeId ?? theme.settingsId;

  final ColorThemeData theme;
  final String themeId;
  final Map<String, ui.Color?> _colors = {};

  ColorScheme get type => theme.type;
  bool get dark => isDark(type);
  bool get highContrast => isHighContrast(type);

  /// The color [id] names; null when neither the theme nor the registry
  /// gives it one.
  ui.Color? get(String id) => _colors.putIfAbsent(id, () {
    if (!highContrast) {
      final overridden = ThemePaletteOverrides.resolveOverride(
        id,
        themeId: themeId,
        dark: dark,
      );
      if (overridden != null) return overridden;
    }
    final color = theme.getColor(id);
    return color == null ? null : toFlutterColor(color);
  });

  /// [get], else what the element would inherit upstream: a text color
  /// without one (`sideBar.foreground`, `list.hoverForeground`…) leaves CSS
  /// `color` inherited, ending at the workbench's `foreground`; any other
  /// color (a background, a border) is none, so transparent.
  ui.Color operator [](String id) =>
      get(id) ??
      (id != 'foreground' && id.endsWith('oreground')
          ? get('foreground')
          : null) ??
      const ui.Color(0x00000000);

  /// A VS Code color as Flutter paints it.
  static ui.Color toFlutterColor(vs.Color color) {
    final rgba = color.rgba;
    return ui.Color.fromARGB((rgba.a * 255).round(), rgba.r, rgba.g, rgba.b);
  }
}

/// The current color theme's colors, as widgets read them
/// ([WorkbenchThemeService.instance]'s).
WorkbenchColors get themeColors => WorkbenchThemeService.instance.colors;

/// The workbench's color theme service (upstream `IWorkbenchThemeService`,
/// color themes only). One per app: [instance]. Preferences: Color Theme
/// picks from it ([IdeColorThemeController]).
class WorkbenchThemeService extends ChangeNotifier
    implements IdeColorThemeController, TextMateThemeSource {
  WorkbenchThemeService({this.bundle, ColorThemeData? initial})
    : _current =
          initial ??
          ColorThemeData.createUnloadedThemeForThemeType(
            ColorScheme.dark,
            colorThemeDarkInitialColors,
          );

  /// The app's service; tests replace it.
  static WorkbenchThemeService instance = WorkbenchThemeService();

  /// Where the themes are read; [rootBundle] when null.
  final AssetBundle? bundle;
  AssetBundle get _assets => bundle ?? rootBundle;

  ColorThemeData _current;
  WorkbenchColors? _colors;

  /// Where the choice is kept; none under test.
  ColorThemeStorage? storage;

  /// The `workbench.colorTheme` setting kept, apart from the theme Auto
  /// shows.
  String _setting = ThemeSettingDefaults.colorThemeDark;
  bool _automatic = false;
  ColorScheme _committedType = ColorScheme.dark;
  String? _preview;
  ui.Brightness _brightness = ui.PlatformDispatcher.instance.platformBrightness;
  int _request = 0;
  int _preferenceRevision = 0;

  /// The theme kept; Auto leaves it as it is.
  String get colorThemeSetting => _setting;

  /// Whether Auto is kept; a preview does not change it.
  bool get autoDetectColorScheme => _automatic;

  bool get _followsSystem =>
      _preview == IdeColorThemeController.autoId ||
      (_preview == null && _automatic);
  String get _resolvedSetting => _followsSystem
      ? (_brightness == ui.Brightness.light
            ? ThemeSettingDefaults.colorThemeLight
            : ThemeSettingDefaults.colorThemeDark)
      : _preview ?? _setting;

  /// Shows a change of theme to [colors]: [apply] once, unless another
  /// came since. Only for one the system's appearance makes.
  void Function(WorkbenchColors colors, VoidCallback apply)? transition;

  /// The current theme: from storage or a type's initial colors until the
  /// theme file is loaded ([ColorThemeData.isLoaded]).
  @override
  ColorThemeData get colorTheme => _current;

  /// The choice as the picker has it: Auto's, or the theme's settings id.
  @override
  String get colorThemeId =>
      _preview ??
      (_automatic
          ? IdeColorThemeController.autoId
          : (_current.settingsId.startsWith('__')
                ? _setting
                : _current.settingsId));

  WorkbenchColors get colors => _colors ??= WorkbenchColors(
    _current,
    themeId: _current.settingsId.startsWith('__')
        ? _resolvedSetting
        : _current.settingsId,
  );

  /// Clears the cached [WorkbenchColors] and notifies listeners when
  /// [ThemePaletteOverrides] change.
  void invalidateColors() {
    _colors = null;
    notifyListeners();
  }

  // --- The bundled & user themes ------------------------------------------

  TextMateManifest? _manifest;
  final Map<String, ColorThemeData> _themes = {};
  final Map<String, ColorThemeData> _userThemes = {};
  final Map<String, String> _inMemoryUserThemes = {};
  final Set<String> _deletedThemes = {};
  final Set<String> _preloadingIds = {};

  Future<String> _read(String path) async {
    if (_inMemoryUserThemes[path] case final memoryText?) {
      return memoryText;
    }
    // An extension's or user custom theme: its file on disk.
    if (p.isAbsolute(path)) {
      return decodeTextMateResource(await File(path).readAsBytes());
    }
    final data = await _assets.load('$textMateAssetRoot/$path');
    return decodeTextMateResource(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  }

  Future<TextMateManifest> _loadManifest() async =>
      _manifest ??= await TextMateManifest.load(_read);

  /// Synchronizes user-created custom themes (`<dataDir>/themes/`) and
  /// hidden built-in themes.
  Future<void> syncUserThemes({
    required List<CustomThemeRecord> records,
    required Set<String> deletedIds,
    required String? dataDir,
    Map<String, Map<String, Object?>>? preloadedJson,
  }) => _queue(() async {
    _deletedThemes
      ..clear()
      ..addAll(deletedIds);
    final next = <String, ColorThemeData>{};
    for (final record in records) {
      final point = IThemeExtensionPoint(
        id: record.id,
        label: record.label,
        path: record.path,
        uiTheme: record.uiTheme,
      );
      final String location;
      if (dataDir != null && dataDir.isNotEmpty) {
        location = p
            .normalize(p.join(dataDir, 'themes', record.path))
            .replaceAll(r'\', '/');
      } else {
        location = '__memory__/${record.path}';
        if (preloadedJson?[record.path] case final map?) {
          _inMemoryUserThemes[location] = jsonEncode(map);
        }
      }
      next[record.id] = ColorThemeData.fromExtensionTheme(
        point,
        location,
        extensionId: 'user.custom-themes',
      );
    }
    _userThemes
      ..clear()
      ..addAll(next);
    await _loadCurrent(_request);
    notifyListeners();
  });

  /// Returns a standalone VS Code theme JSON map for [baseThemeId] with any
  /// relative `"include"` chains recursively flattened.
  Future<Map<String, Object?>> readStandaloneThemeMap(
    String baseThemeId, {
    required bool dark,
  }) async {
    final manifest = await _loadManifest();
    String? location = manifest.themeById(baseThemeId)?.assetPath;
    location ??= _userThemes[baseThemeId]?.location;
    location ??= _extensionThemes[baseThemeId]?.location;
    location ??= manifest
        .themeById(
          dark
              ? ThemeSettingDefaults.colorThemeDark
              : ThemeSettingDefaults.colorThemeLight,
        )
        ?.assetPath;
    if (location == null) {
      return <String, Object?>{
        'name': baseThemeId,
        'type': dark ? 'dark' : 'light',
        'colors': <String, Object?>{},
        'tokenColors': <Object?>[],
      };
    }
    return _loadMergedThemeJson(location);
  }

  Future<Map<String, Object?>> _loadMergedThemeJson(
    String location, [
    int depth = 0,
  ]) async {
    if (depth > 8) return <String, Object?>{};
    String text;
    try {
      text = await _read(location);
    } catch (_) {
      return <String, Object?>{};
    }
    final decoded = vs_json.parse(text);
    if (decoded is! Map) return <String, Object?>{};
    final current = <String, Object?>{
      for (final e in decoded.entries) '${e.key}': e.value,
    };
    final include = current.remove('include');
    if (include is! String || include.isEmpty) return current;
    final String parentPath;
    if (p.isAbsolute(location)) {
      parentPath = p
          .normalize(p.join(p.dirname(location), include))
          .replaceAll(r'\', '/');
    } else {
      final dir = p.posix.dirname(location.replaceAll(r'\', '/'));
      parentPath = p.posix.normalize('$dir/$include');
    }
    final base = await _loadMergedThemeJson(parentPath, depth + 1);
    final mergedColors = <String, Object?>{
      if (base['colors'] case final Map m)
        for (final e in m.entries) '${e.key}': e.value,
      if (current['colors'] case final Map m)
        for (final e in m.entries) '${e.key}': e.value,
    };
    final mergedTokens = <Object?>[
      if (base['tokenColors'] case final List l) ...l,
      if (current['tokenColors'] case final List l) ...l,
    ];
    final mergedSemantic = <String, Object?>{
      if (base['semanticTokenColors'] case final Map m)
        for (final e in m.entries) '${e.key}': e.value,
      if (current['semanticTokenColors'] case final Map m)
        for (final e in m.entries) '${e.key}': e.value,
    };
    return <String, Object?>{
      ...base,
      ...current,
      if (mergedColors.isNotEmpty) 'colors': mergedColors,
      if (mergedTokens.isNotEmpty) 'tokenColors': mergedTokens,
      if (mergedSemantic.isNotEmpty) 'semanticTokenColors': mergedSemantic,
    };
  }

  /// Factory (un-overridden) colors of the 6 customizable slots for [themeId].
  /// Triggers an asynchronous load if [themeId] is not yet loaded in memory.
  Map<String, ui.Color> baseSlotColors(
    String themeId, {
    required bool dark,
  }) {
    final data =
        _themes[themeId] ?? _userThemes[themeId] ?? _extensionThemes[themeId];
    if (data == null || !data.isLoaded) {
      if (!_preloadingIds.contains(themeId)) {
        _preloadingIds.add(themeId);
        unawaited(
          _loadTheme(themeId)
              .then((loaded) {
                if (loaded != null) notifyListeners();
              })
              .whenComplete(() => _preloadingIds.remove(themeId)),
        );
      }
      return {
        ThemePaletteOverrides.slotBackground: dark
            ? ThemePaletteOverrides.defaultDarkBackground
            : ThemePaletteOverrides.defaultLightBackground,
        ThemePaletteOverrides.slotSidebar: dark
            ? ThemePaletteOverrides.defaultDarkSidebar
            : ThemePaletteOverrides.defaultLightSidebar,
        ThemePaletteOverrides.slotCard: dark
            ? ThemePaletteOverrides.defaultDarkCard
            : ThemePaletteOverrides.defaultLightCard,
        ThemePaletteOverrides.slotForeground: dark
            ? ThemePaletteOverrides.defaultDarkForeground
            : ThemePaletteOverrides.defaultLightForeground,
        ThemePaletteOverrides.slotAccent: dark
            ? ThemePaletteOverrides.defaultDarkAccent
            : ThemePaletteOverrides.defaultLightAccent,
        ThemePaletteOverrides.slotInlineCode: dark
            ? ThemePaletteOverrides.defaultDarkInlineCode
            : ThemePaletteOverrides.defaultLightInlineCode,
      };
    }

    final raw = WorkbenchColors(data, themeId: '__unoverridden__');
    ui.Color opaqueOver(ui.Color? c, ui.Color under) {
      if (c == null || c.a == 0) return under;
      return c.a < 1.0 ? ui.Color.alphaBlend(c, under) : c;
    }

    final bg =
        raw.get('editor.background') ??
        (dark
            ? ThemePaletteOverrides.defaultDarkBackground
            : ThemePaletteOverrides.defaultLightBackground);
    final sb = opaqueOver(raw.get('sideBar.background'), bg);
    final card = opaqueOver(
      raw.get('agentsChatInput.background') ??
          raw.get('chat.requestBubbleBackground') ??
          raw.get('list.activeSelectionBackground'),
      bg,
    );
    final fg =
        raw.get('editor.foreground') ??
        raw.get('foreground') ??
        (dark
            ? ThemePaletteOverrides.defaultDarkForeground
            : ThemePaletteOverrides.defaultLightForeground);
    final accent =
        raw.get('button.background') ??
        raw.get('textLink.foreground') ??
        raw.get('focusBorder') ??
        (dark
            ? ThemePaletteOverrides.defaultDarkAccent
            : ThemePaletteOverrides.defaultLightAccent);
    final inlineCode = raw.get('textPreformat.foreground') ?? fg;

    return {
      ThemePaletteOverrides.slotBackground: bg,
      ThemePaletteOverrides.slotSidebar: sb,
      ThemePaletteOverrides.slotCard: card,
      ThemePaletteOverrides.slotForeground: fg,
      ThemePaletteOverrides.slotAccent: accent,
      ThemePaletteOverrides.slotInlineCode: inlineCode,
    };
  }

  /// The installed themes (`getColorThemes`), by settings id, once
  /// [initialize] has read them.
  @override
  List<IdeColorThemeEntry> get colorThemes => [
    for (final theme
        in _manifest?.themes ?? const <TextMateThemeContribution>[])
      if (!_deletedThemes.contains(theme.id))
        IdeColorThemeEntry(
          id: theme.id,
          label: theme.label,
          type: _themeData(theme).type,
        ),
    for (final theme in _userThemes.values)
      IdeColorThemeEntry(
        id: theme.settingsId,
        label: theme.label,
        type: theme.type,
        description: theme.description,
      ),
    for (final theme in _extensionThemes.values)
      if (!_deletedThemes.contains(theme.settingsId))
        IdeColorThemeEntry(
          id: theme.settingsId,
          label: theme.label,
          type: theme.type,
          description: theme.description,
        ),
  ];

  // --- Extensions' colors (`contributes.colors`) ---------------------------

  /// The color ids the running extensions registered.
  final Set<String> _extensionColorIds = {};
  String? _extensionColorsKey;

  static final _colorIdPattern = RegExp(r'^\w+[.\w+]*$');

  void setExtensionColors(Iterable<List<Map<String, Object?>>> colors) {
    final key = jsonEncode(colors.toList());
    if (key == _extensionColorsKey) return;
    _extensionColorsKey = key;
    final registry = getColorRegistry();
    for (final id in _extensionColorIds) {
      registry.deregisterColor(id);
    }
    _extensionColorIds.clear();
    ColorValue? value(String s) => s.isEmpty
        ? const ColorLiteral('#ff0000')
        : s.startsWith('#')
        ? (vs.ColorFormatCSS.parseHex(s) == null ? null : ColorLiteral(s))
        : ColorReference(s);
    for (final entries in colors) {
      for (final entry in entries) {
        final id = entry['id'];
        final defaults = entry['defaults'];
        if (id is! String || !_colorIdPattern.hasMatch(id)) break;
        if (entry['description'] is! String) break;
        if (defaults is! Map ||
            defaults['light'] is! String ||
            defaults['dark'] is! String) {
          break;
        }
        final highContrast = defaults['highContrast'];
        final highContrastLight = defaults['highContrastLight'];
        if (highContrast is! String? || highContrastLight is! String?) break;
        final light = defaults['light'] as String;
        final dark = defaults['dark'] as String;
        registry.registerColor(
          id,
          ColorDefaults(
            light: value(light),
            dark: value(dark),
            hcDark: value(highContrast ?? dark),
            hcLight: value(highContrastLight ?? light),
          ),
        );
        _extensionColorIds.add(id);
      }
    }
    _current.clearCaches();
    _colors = null;
    notifyListeners();
  }

  // --- Extensions' themes (`contributes.themes`) ---------------------------

  final Map<String, ColorThemeData> _extensionThemes = {};
  bool _extensionThemesKnown = false;
  bool waitsForExtensionThemes = false;

  Future<void> setExtensionThemes(
    Iterable<
      ({String extensionId, String location, Map<String, Object?> theme})
    >
    themes,
  ) => _queue(() async {
    final next = <String, ColorThemeData>{};
    for (final (:extensionId, :location, :theme) in themes) {
      final path = theme['path'];
      if (path is! String || path.isEmpty) continue;
      final label = theme['label'] is String ? theme['label']! as String : null;
      final id = theme['id'] is String ? theme['id']! as String : label ?? path;
      final point = IThemeExtensionPoint(
        id: id,
        label: label,
        description: theme['description'] as String?,
        path: path,
        uiTheme: theme['uiTheme'] as String?,
      );
      final file = p.normalize(p.join(location, path)).replaceAll(r'\', '/');
      final kept = _extensionThemes[id];
      next[id] = kept != null && kept.location == file
          ? kept
          : ColorThemeData.fromExtensionTheme(
              point,
              file,
              extensionId: extensionId,
            );
    }
    _extensionThemes
      ..clear()
      ..addAll(next);
    _extensionThemesKnown = true;
    await _loadCurrent(_request);
    notifyListeners();
  });

  String get _defaultSetting => _committedType == ColorScheme.light
      ? ThemeSettingDefaults.colorThemeLight
      : ThemeSettingDefaults.colorThemeDark;

  ColorThemeData _themeData(TextMateThemeContribution theme) =>
      _themes[theme.id] ??= ColorThemeData.fromExtensionTheme(
        theme,
        theme.assetPath,
        extensionId: theme.extensionId,
      );

  // --- Startup ------------------------------------------------------------

  void restore({
    String? setting,
    String? data,
    bool autoDetectColorScheme = false,
    ui.Brightness? brightness,
  }) {
    _request++;
    _preferenceRevision++;
    _preview = null;
    _automatic = autoDetectColorScheme;
    _brightness =
        brightness ?? ui.PlatformDispatcher.instance.platformBrightness;
    if (setting != null && setting.isNotEmpty) {
      _setting = migrateThemeSettingsId(setting);
    }
    final id = _resolvedSetting;
    var theme = ColorThemeData.fromStorageData(data);
    if (theme != null && theme.settingsId != id) theme = null;
    theme ??= ColorThemeData.createUnloadedThemeForThemeType(
      id == ThemeSettingDefaults.colorThemeLight
          ? ColorScheme.light
          : ColorScheme.dark,
      switch (id) {
        ThemeSettingDefaults.colorThemeLight => colorThemeLightInitialColors,
        ThemeSettingDefaults.colorThemeDark => colorThemeDarkInitialColors,
        _ => null,
      },
    );
    _apply(theme, silent: true);
  }

  Future<void> initialize() {
    final request = _request;
    return _queue(() => _loadCurrent(request));
  }

  Future<ColorThemeData?> _loadTheme(String id) async {
    if (_deletedThemes.contains(id)) return null;
    final theme = (await _loadManifest()).themeById(id);
    final data = theme != null
        ? _themeData(theme)
        : (_userThemes[id] ?? _extensionThemes[id]);
    if (data != null) {
      try {
        await data.ensureLoaded(_read);
      } catch (error) {
        debugPrint('Color theme load failed ($id): $error');
        return null;
      }
    }
    return data;
  }

  Future<void> _loadCurrent(int request, {bool force = false}) async {
    if (request != _request) return;
    var id = _resolvedSetting;
    var data = await _loadTheme(id);
    var fallback = false;
    if (request != _request || id != _resolvedSetting) return;
    if (data == null) {
      fallback = true;
      if (waitsForExtensionThemes && !_extensionThemesKnown) return;
      id = _defaultSetting;
      data = await _loadTheme(id);
      if (request != _request || data == null) return;
      if (_preview != null) {
        _preview = id;
      } else if (!_automatic) {
        try {
          await _keep(data, setting: id, automatic: false);
        } catch (error) {
          debugPrint('Fallback color theme not kept: $error');
        }
        if (request != _request) return;
      }
    }
    if (force || !identical(data, _current)) {
      _apply(data, preview: _preview != null, fallback: fallback);
    }
    if (_preview == null) await _remember(data);
  }

  Future<void> _remember(ColorThemeData theme) async {
    try {
      await storage?.storeColorTheme(
        setting: _setting,
        data: theme.toStorage(),
        autoDetectColorScheme: _automatic,
        cacheOnly: true,
      );
    } catch (error) {
      debugPrint('Color theme cache not kept: $error');
    }
  }

  @override
  Future<ColorThemeData> loadedColorTheme() async {
    if (!_current.isLoaded) await initialize();
    return _current;
  }

  // --- Changing it ----------------------------------------------------------

  Future<void> _pending = Future.value();

  Future<T> _queue<T>(Future<T> Function() change) {
    final result = _pending.then((_) => change());
    _pending = result.then((_) {}, onError: (_) {});
    return result;
  }

  @override
  Future<void> setColorTheme(String settingsId, {bool preview = false}) {
    final request = ++_request;
    return _queue(
      () => _setColorTheme(settingsId, preview: preview, request: request),
    );
  }

  @override
  Future<void> restoreColorThemePreview() {
    final request = ++_request;
    _preview = null;
    return _queue(() => _loadCurrent(request, force: true));
  }

  Future<void> applyColorThemeSettings({
    required String setting,
    required bool autoDetectColorScheme,
  }) {
    final request = ++_request;
    final revision = ++_preferenceRevision;
    final id = _setting = migrateThemeSettingsId(setting);
    _automatic = autoDetectColorScheme;
    _preview = null;
    return _queue(() async {
      final manifest = await _loadManifest();
      if (revision == _preferenceRevision) {
        final theme = manifest.themeById(id);
        final data = theme != null
            ? _themeData(theme)
            : (_userThemes[id] ?? _extensionThemes[id]);
        if (data != null) _committedType = data.type;
      }
      await _loadCurrent(request, force: true);
    });
  }

  Future<void> setPlatformBrightness(ui.Brightness brightness) {
    if (_brightness == brightness) return Future<void>.value();
    _brightness = brightness;
    if (!_followsSystem) return Future<void>.value();
    final request = _request;
    return _queue(() async {
      _bySystem = true;
      try {
        await _loadCurrent(request, force: true);
      } finally {
        _bySystem = false;
      }
    });
  }

  bool _bySystem = false;

  Future<void> _setColorTheme(
    String settingsId, {
    required bool preview,
    required int request,
  }) async {
    if (request != _request) return;
    final automatic = settingsId == IdeColorThemeController.autoId;
    final id = automatic
        ? (_brightness == ui.Brightness.light
              ? ThemeSettingDefaults.colorThemeLight
              : ThemeSettingDefaults.colorThemeDark)
        : settingsId;
    try {
      final data = await _loadTheme(id);
      if (request != _request) return;
      if (data == null) {
        throw StateError('Color theme no longer available: $id');
      }
      if (preview) {
        _preview = settingsId;
      } else {
        await _keep(
          data,
          setting: automatic ? _setting : settingsId,
          automatic: automatic,
        );
        if (request != _request) return;
        _preview = null;
      }
      if (data.settingsId != _resolvedSetting) {
        await _loadCurrent(request, force: true);
      } else {
        _apply(data, preview: preview);
      }
    } catch (_) {
      if (request == _request) {
        _preview = null;
        await _loadCurrent(request, force: true).catchError((Object error) {
          debugPrint('Color theme not restored: $error');
        });
      }
      rethrow;
    }
  }

  void _apply(
    ColorThemeData theme, {
    bool silent = false,
    bool preview = true,
    bool fallback = false,
  }) {
    final request = _request;
    void apply() {
      if (request != _request ||
          theme.settingsId != _resolvedSetting && !silent && !fallback) {
        return;
      }
      _current.clearCaches();
      _current = theme;
      if (silent || !preview) _committedType = theme.type;
      _colors = null;
      appEvent(
        'theme',
        '${theme.settingsId} (${theme.type.name}'
            '${theme.isLoaded ? '' : ', not loaded'}'
            '${silent
                ? ', restored'
                : preview
                ? ', preview'
                : ''})',
      );
      if (!silent) notifyListeners();
    }

    final animate = transition;
    if (!silent &&
        _bySystem &&
        animate != null &&
        _current.isLoaded &&
        theme.isLoaded) {
      animate(WorkbenchColors(theme), apply);
    } else {
      apply();
    }
  }

  Future<void> _keep(
    ColorThemeData theme, {
    required String setting,
    required bool automatic,
  }) async {
    final revision = _preferenceRevision;
    final store = storage;
    await store?.storeColorTheme(
      setting: setting,
      data: theme.toStorage(),
      autoDetectColorScheme: automatic,
    );
    if (revision == _preferenceRevision) {
      _setting = store == null
          ? setting
          : migrateThemeSettingsId(
              store.colorThemeSetting ?? ThemeSettingDefaults.colorThemeDark,
            );
      _automatic = store?.autoDetectColorScheme ?? automatic;
      _committedType = theme.type;
      _preferenceRevision++;
    }
  }

  @override
  void dispose() {
    _request++;
    transition = null;
    super.dispose();
  }
}

/// Rebuilds everything under it when the workbench theme changes, as a
/// theme change restyles the whole workbench upstream: widgets read colors
/// from [WorkbenchThemeService.instance] without depending on it. So, too,
/// when [restyle] notifies.
class WorkbenchThemeScope extends StatefulWidget {
  const WorkbenchThemeScope({
    super.key,
    this.service,
    this.restyle,
    required this.builder,
  });

  final WorkbenchThemeService? service;
  final Listenable? restyle;
  final WidgetBuilder builder;

  static int get restyles => _restyles;
  static int _restyles = 0;

  @override
  State<WorkbenchThemeScope> createState() => _WorkbenchThemeScopeState();
}

class _WorkbenchThemeScopeState extends State<WorkbenchThemeScope> {
  late WorkbenchThemeService _service =
      widget.service ?? WorkbenchThemeService.instance;

  @override
  void initState() {
    super.initState();
    _service.addListener(_changed);
    widget.restyle?.addListener(_changed);
  }

  @override
  void didUpdateWidget(WorkbenchThemeScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    final service = widget.service ?? WorkbenchThemeService.instance;
    if (!identical(service, _service)) {
      _service.removeListener(_changed);
      _service = service..addListener(_changed);
    }
    if (!identical(widget.restyle, oldWidget.restyle)) {
      oldWidget.restyle?.removeListener(_changed);
      widget.restyle?.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _service.removeListener(_changed);
    widget.restyle?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    WorkbenchThemeScope._restyles++;
    void rebuild(Element element) {
      element.markNeedsBuild();
      element.visitChildren(rebuild);
    }

    (context as Element).visitChildren(rebuild);
    setState(() {});
    void repaint(RenderObject object) {
      object.markNeedsPaint();
      object.visitChildren(repaint);
    }

    for (final view in WidgetsBinding.instance.renderViews) {
      repaint(view);
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
