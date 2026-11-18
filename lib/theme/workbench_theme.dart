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
//
// Deviations: settings and storage are two preference entries the app keeps
// (`ColorThemeStorage`), read once at startup; no customizations, transient
// colors, theme watching, telemetry, or file or product icon themes.
// Auto (`window.autoDetectColorScheme`) is Bao Light or Bao Dark by the
// system's appearance; no preferred light or dark theme settings.
// Widgets read colors through [WorkbenchThemeService.colors] and are all
// rebuilt when the theme changes ([WorkbenchThemeScope]), as a theme change
// restyles the whole workbench upstream.

import 'dart:async';
import 'dart:convert' show JsonEncoder, jsonDecode, jsonEncode;
import 'dart:io' show Directory, File;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:bao_editor/monaco/vs/base/common/color.dart' as vs;
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
  static const defaultLightForeground = ui.Color(0xFF2B2A28);
  static const defaultLightAccent = ui.Color(0xFF3E8ED1);

  static const defaultDarkBackground = ui.Color(0xFF1D1C1A);
  static const defaultDarkForeground = ui.Color(0xFFE6E3DC);
  static const defaultDarkAccent = ui.Color(0xFFD47F60);

  static final ValueNotifier<int> _revision = ValueNotifier<int>(0);
  static Listenable get changes => _revision;

  /// `themeId -> { slot -> Color }`.
  static final Map<String, Map<String, ui.Color>> _overrides = {};
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
      final customRaw = read(customThemesKey);
      final deletedRaw = read(deletedThemesKey);
      WorkbenchThemeService.instance.syncUserThemes(
        customRaw: customRaw,
        deletedRaw: deletedRaw,
        dataDir: dataDir,
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

  /// Updates [slot] in memory and repaints immediately without disk I/O (used
  /// during live HSV color picker dragging; call [setSlotColor] on commit).
  static void previewSlotColor(
    String themeId,
    String slot,
    ui.Color? color,
  ) {
    if (color == null) {
      final slots = _overrides[themeId];
      slots?.remove(slot);
      if (slots != null && slots.isEmpty) _overrides.remove(themeId);
    } else {
      (_overrides[themeId] ??= {})[slot] = color;
    }
    _notify();
  }

  static Future<void> setSlotColor(
    String themeId,
    String slot,
    ui.Color? color,
  ) async {
    previewSlotColor(themeId, slot, color);
    await _persistKey(overridesKey, _serializeOverrides());
  }

  static Future<void> resetTheme(String themeId) async {
    if (_overrides.remove(themeId) == null) return;
    _notify();
    await _persistKey(overridesKey, _serializeOverrides());
  }

  static Future<void> moveOverrides(String fromId, String toId) async {
    final moved = _overrides.remove(fromId);
    if (moved == null) return;
    _overrides[toId] = moved;
    _notify();
    await _persistKey(overridesKey, _serializeOverrides());
  }

  @visibleForTesting
  static void resetForTesting() {
    _overrides.clear();
    _writer = null;
    _dataDir = null;
    _syncingFromSettings = false;
    _revision.value++;
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
  WorkbenchColors(this.theme);

  final ColorThemeData theme;
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
        themeId: theme.settingsId,
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
            ? _preferredLightThemeId
            : _preferredDarkThemeId)
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

  WorkbenchColors get colors => _colors ??= WorkbenchColors(_current);

  /// Clears the cached [WorkbenchColors] and notifies listeners when
  /// [ThemePaletteOverrides] change.
  void invalidateColors() {
    _colors = null;
    notifyListeners();
  }

  // --- The bundled themes -------------------------------------------------

  TextMateManifest? _manifest;
  final Map<String, ColorThemeData> _themes = {};

  Future<String> _read(String path) async {
    // An extension's theme: its file on disk.
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
    for (final theme in _customThemes.values)
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

  // --- Custom & deleted themes (`workbench.customThemes`, `workbench.deletedThemes`) ---

  final List<Map<String, String>> _customThemeRecords = [];
  final Map<String, ColorThemeData> _customThemes = {};
  final Set<String> _deletedThemes = {};

  bool isCustomTheme(String id) => _customThemes.containsKey(id);
  bool get hasDeletedThemes => _deletedThemes.isNotEmpty;

  String get _preferredLightThemeId {
    if (!_deletedThemes.contains(ThemeSettingDefaults.colorThemeLight)) {
      return ThemeSettingDefaults.colorThemeLight;
    }
    for (final entry in colorThemes) {
      if (entry.type == ColorScheme.light) return entry.id;
    }
    return ThemeSettingDefaults.colorThemeLight;
  }

  String get _preferredDarkThemeId {
    if (!_deletedThemes.contains(ThemeSettingDefaults.colorThemeDark)) {
      return ThemeSettingDefaults.colorThemeDark;
    }
    for (final entry in colorThemes) {
      if (entry.type == ColorScheme.dark) return entry.id;
    }
    return ThemeSettingDefaults.colorThemeDark;
  }

  void syncUserThemes({
    required Object? customRaw,
    required Object? deletedRaw,
    required String dataDir,
  }) {
    _deletedThemes.clear();
    if (deletedRaw is List) {
      for (final item in deletedRaw) {
        if (item is String && item.isNotEmpty) {
          _deletedThemes.add(item);
        }
      }
    }

    _customThemeRecords.clear();
    final nextCustom = <String, ColorThemeData>{};
    if (customRaw is List) {
      for (final item in customRaw) {
        if (item is! Map) continue;
        final id = item['id'];
        final label = item['label'] ?? id;
        final uiTheme = item['uiTheme'];
        final file = item['file'];
        if (id is! String || id.isEmpty || file is! String || file.isEmpty) {
          continue;
        }
        final resolvedLabel = label is String && label.isNotEmpty ? label : id;
        final resolvedUiTheme = uiTheme is String && uiTheme.isNotEmpty
            ? uiTheme
            : 'vs-dark';
        _customThemeRecords.add({
          'id': id,
          'label': resolvedLabel,
          'uiTheme': resolvedUiTheme,
          'file': file,
        });
        final fullPath = p
            .normalize(p.join(dataDir, 'themes', file))
            .replaceAll(r'\', '/');
        final kept = _customThemes[id];
        if (kept != null &&
            kept.location == fullPath &&
            kept.label == resolvedLabel) {
          nextCustom[id] = kept;
        } else {
          nextCustom[id] = ColorThemeData.fromExtensionTheme(
            IThemeExtensionPoint(
              id: id,
              label: resolvedLabel,
              path: file,
              uiTheme: resolvedUiTheme,
            ),
            fullPath,
            extensionId: 'user.custom',
          );
        }
      }
    }
    _customThemes
      ..clear()
      ..addAll(nextCustom);

    if (_manifest != null) {
      unawaited(_queue(() => _loadCurrent(_request)));
    }
  }

  /// Loads [id] (bundled, custom, or extension) and returns its underlying
  /// [ColorThemeData] (before [ThemePaletteOverrides]).
  Future<ColorThemeData?> loadThemeData(String id) async {
    if (id == _current.settingsId && _current.isLoaded) {
      return _current;
    }
    return _loadTheme(id);
  }

  /// Loads [id] (bundled, custom, or extension) and returns its resolved
  /// [WorkbenchColors] including any [ThemePaletteOverrides].
  Future<WorkbenchColors?> previewThemeColors(String id) async {
    final data = await loadThemeData(id);
    if (data == null) return null;
    return WorkbenchColors(data);
  }

  /// Creates a standalone custom theme JSON file on disk, registers it in
  /// `workbench.customThemes`, activates it, and returns its unique ID.
  Future<String> createCustomTheme({
    required String name,
    required bool dark,
    String? baseId,
    Map<String, ui.Color>? initialSlots,
  }) async {
    await _loadManifest();
    var trimmed = name.trim();
    if (trimmed.isEmpty) {
      trimmed = dark ? 'Custom Dark' : 'Custom Light';
    }
    final existingIds = {
      for (final t in colorThemes) t.id.toLowerCase(),
      for (final r in _customThemeRecords) r['id']!.toLowerCase(),
    };
    var candidate = trimmed;
    var suffix = 2;
    while (existingIds.contains(candidate.toLowerCase())) {
      candidate = '$trimmed ($suffix)';
      suffix++;
    }
    if (_deletedThemes.remove(candidate)) {
      await ThemePaletteOverrides._persistKey(
        ThemePaletteOverrides.deletedThemesKey,
        _deletedThemes.isEmpty ? null : (_deletedThemes.toList()..sort()),
      );
    }

    final resolvedBaseId =
        baseId ?? (dark ? _preferredDarkThemeId : _preferredLightThemeId);
    final baseData =
        await _loadTheme(resolvedBaseId) ??
        await _loadTheme(
          dark
              ? ThemeSettingDefaults.colorThemeDark
              : ThemeSettingDefaults.colorThemeLight,
        );

    final mergedColors = <String, String>{
      if (baseData != null) ...baseData.colors,
    };
    final mergedSlots = <String, ui.Color>{
      ...ThemePaletteOverrides.overridesFor(resolvedBaseId),
      ...?initialSlots,
    };
    if (mergedSlots.isNotEmpty) {
      ThemePaletteOverrides.applySlotsToColorMap(
        mergedColors,
        mergedSlots,
        dark: dark,
      );
    }

    final slugBase = candidate
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fa5_-]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final fileName =
        '${slugBase.isEmpty ? 'theme' : slugBase}-${DateTime.now().millisecondsSinceEpoch}.json';
    final rootDir =
        ThemePaletteOverrides._dataDir ?? Directory.systemTemp.path;
    final themesDir = Directory(p.join(rootDir, 'themes'));
    await themesDir.create(recursive: true);
    final fullPath = p
        .normalize(p.join(themesDir.path, fileName))
        .replaceAll(r'\', '/');

    final jsonContent = const JsonEncoder.withIndent('  ').convert({
      r'$schema': 'vscode://schemas/color-theme',
      'name': candidate,
      'type': dark ? 'dark' : 'light',
      if (baseData != null)
        'semanticHighlighting': baseData.semanticHighlighting,
      'colors': mergedColors,
      'tokenColors': baseData?.themeTokenColors ?? const <Object?>[],
    });
    await File(fullPath).writeAsString('$jsonContent\n');

    final uiTheme = dark ? 'vs-dark' : 'vs';
    _customThemeRecords.add({
      'id': candidate,
      'label': candidate,
      'uiTheme': uiTheme,
      'file': fileName,
    });
    final themeData = ColorThemeData.fromExtensionTheme(
      IThemeExtensionPoint(
        id: candidate,
        label: candidate,
        path: fileName,
        uiTheme: uiTheme,
      ),
      fullPath,
      extensionId: 'user.custom',
    );
    await themeData.ensureLoaded(_read);
    _customThemes[candidate] = themeData;

    await ThemePaletteOverrides._persistKey(
      ThemePaletteOverrides.customThemesKey,
      _customThemeRecords.map((r) => Map<String, Object?>.of(r)).toList(),
    );
    notifyListeners();
    await setColorTheme(candidate);
    return candidate;
  }

  /// Renames a user-created custom theme and updates settings & active state.
  Future<String> renameCustomTheme(String id, String newName) async {
    final index = _customThemeRecords.indexWhere((r) => r['id'] == id);
    if (index < 0) return id;
    var trimmed = newName.trim();
    if (trimmed.isEmpty || trimmed == id) return id;
    final existingIds = {
      for (final t in colorThemes)
        if (t.id != id) t.id.toLowerCase(),
      for (final r in _customThemeRecords)
        if (r['id'] != id) r['id']!.toLowerCase(),
    };
    var candidate = trimmed;
    var suffix = 2;
    while (existingIds.contains(candidate.toLowerCase())) {
      candidate = '$trimmed ($suffix)';
      suffix++;
    }

    final record = Map<String, String>.of(_customThemeRecords[index]);
    record['id'] = candidate;
    record['label'] = candidate;
    _customThemeRecords[index] = record;

    final oldData = _customThemes.remove(id);
    final rootDir =
        ThemePaletteOverrides._dataDir ?? Directory.systemTemp.path;
    final fullPath =
        oldData?.location ??
        p
            .normalize(p.join(rootDir, 'themes', record['file']!))
            .replaceAll(r'\', '/');

    try {
      final file = File(fullPath);
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map<String, Object?>) {
          decoded['name'] = candidate;
          await file.writeAsString(
            '${const JsonEncoder.withIndent('  ').convert(decoded)}\n',
          );
        }
      }
    } catch (error) {
      debugPrint('Custom theme file rename update skipped: $error');
    }

    final newData = ColorThemeData.fromExtensionTheme(
      IThemeExtensionPoint(
        id: candidate,
        label: candidate,
        path: record['file']!,
        uiTheme: record['uiTheme'],
      ),
      fullPath,
      extensionId: 'user.custom',
    );
    await newData.ensureLoaded(_read);
    _customThemes[candidate] = newData;

    await ThemePaletteOverrides.moveOverrides(id, candidate);
    await ThemePaletteOverrides._persistKey(
      ThemePaletteOverrides.customThemesKey,
      _customThemeRecords.map((r) => Map<String, Object?>.of(r)).toList(),
    );
    if (_setting == id || _current.settingsId == id) {
      await setColorTheme(candidate);
    } else {
      notifyListeners();
    }
    return candidate;
  }

  /// Deletes a custom theme (removing its JSON file) or hides a built-in
  /// theme in `workbench.deletedThemes`. Always preserves at least one theme
  /// per color scheme (Light / Dark).
  Future<bool> deleteTheme(String id) async {
    await _loadManifest();
    final target = colorThemes.where((t) => t.id == id).firstOrNull;
    if (target == null) return false;
    final sameSchemeRemaining = colorThemes
        .where((t) => isDark(t.type) == isDark(target.type) && t.id != id)
        .toList();
    if (sameSchemeRemaining.isEmpty) return false;

    final wasCustom = _customThemes.containsKey(id);
    if (wasCustom) {
      final removed = _customThemes.remove(id);
      _customThemeRecords.removeWhere((r) => r['id'] == id);
      await ThemePaletteOverrides._persistKey(
        ThemePaletteOverrides.customThemesKey,
        _customThemeRecords.isEmpty
            ? null
            : _customThemeRecords
                  .map((r) => Map<String, Object?>.of(r))
                  .toList(),
      );
      if (removed?.location case final loc?) {
        try {
          final f = File(loc);
          if (await f.exists()) await f.delete();
        } catch (error) {
          debugPrint('Custom theme file delete skipped: $error');
        }
      }
    } else {
      _deletedThemes.add(id);
      await ThemePaletteOverrides._persistKey(
        ThemePaletteOverrides.deletedThemesKey,
        _deletedThemes.toList()..sort(),
      );
    }

    await ThemePaletteOverrides.resetTheme(id);

    if (_setting == id || _current.settingsId == id || _preview == id) {
      await setColorTheme(sameSchemeRemaining.first.id);
    } else {
      notifyListeners();
    }
    return true;
  }

  /// Restores any built-in themes previously hidden via [deleteTheme].
  Future<void> restoreDeletedThemes() async {
    if (_deletedThemes.isEmpty) return;
    _deletedThemes.clear();
    await ThemePaletteOverrides._persistKey(
      ThemePaletteOverrides.deletedThemesKey,
      null,
    );
    notifyListeners();
  }

  // --- Extensions' colors (`contributes.colors`) ---------------------------

  /// The color ids the running extensions registered.
  final Set<String> _extensionColorIds = {};
  String? _extensionColorsKey;

  static final _colorIdPattern = RegExp(r'^\w+[.\w+]*$');

  /// The running extensions' `contributes.colors` (colorExtensionPoint.ts
  /// `ColorExtensionPoint`): each `{id, description, defaults}` registered
  /// in the color registry with its defaults, a '#' string a color and
  /// anything else the color it names; those no longer contributed are
  /// deregistered. [colors] are each extension's entries, in order.
  ///
  /// Deviation: an invalid entry skips the rest of its extension's
  /// (upstream it ends the whole delta's handling).
  void setExtensionColors(Iterable<List<Map<String, Object?>>> colors) {
    final key = jsonEncode(colors.toList());
    if (key == _extensionColorsKey) return;
    _extensionColorsKey = key;
    final registry = getColorRegistry();
    for (final id in _extensionColorIds) {
      registry.deregisterColor(id);
    }
    _extensionColorIds.clear();
    // `parseColorValue`: an empty value is an error, and red.
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
    // Colors are read again, through the registry's new defaults.
    _current.clearCaches();
    _colors = null;
    notifyListeners();
  }

  // --- Extensions' themes (`contributes.themes`) ---------------------------

  /// The installed extensions' themes, by settings id.
  final Map<String, ColorThemeData> _extensionThemes = {};

  /// Whether the extensions' themes were told once: until then, a setting
  /// that is not a bundled theme may be one of theirs, and waits (where
  /// [waitsForExtensionThemes]).
  bool _extensionThemesKnown = false;

  /// Whether extensions will tell their themes ([setExtensionThemes]):
  /// the app with extensions.
  bool waitsForExtensionThemes = false;

  /// The installed extensions' `contributes.themes`: [themes] are each
  /// extension's id, its folder and its contribution (`id`, `label`,
  /// `uiTheme`, `path`). The setting's theme applies once it is among them.
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
      // Kept when unchanged: a loaded theme stays loaded.
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
    // The choice's theme again: an extension's updated or gone too; one
    // loaded is read once.
    await _loadCurrent(_request);
    notifyListeners();
  });

  String get _defaultSetting => _committedType == ColorScheme.light
      ? _preferredLightThemeId
      : _preferredDarkThemeId;

  ColorThemeData _themeData(TextMateThemeContribution theme) =>
      _themes[theme.id] ??= ColorThemeData.fromExtensionTheme(
        theme,
        theme.assetPath,
        extensionId: theme.extensionId,
      );

  // --- Startup ------------------------------------------------------------

  /// The constructor's restore: the kept theme, painted from storage when it
  /// is still the setting's, until [initialize] loads it.
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

  /// Reads the bundled themes and applies the setting's theme, loaded
  /// (`restoreColorTheme`); the default theme when it is gone.
  Future<void> initialize() {
    final request = _request;
    return _queue(() => _loadCurrent(request));
  }

  Future<ColorThemeData?> _loadTheme(String id) async {
    if (_deletedThemes.contains(id)) return null;
    if (_customThemes[id] case final custom?) {
      await custom.ensureLoaded(_read);
      return custom;
    }
    final theme = (await _loadManifest()).themeById(id);
    final data = theme != null ? _themeData(theme) : _extensionThemes[id];
    if (data != null) await data.ensureLoaded(_read);
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
      // Shown even so; a choice failing to be kept throws (see [_keep]).
      debugPrint('Color theme cache not kept: $error');
    }
  }

  /// The current theme, loaded; the setting's when none is.
  @override
  Future<ColorThemeData> loadedColorTheme() async {
    if (!_current.isLoaded) await initialize();
    return _current;
  }

  // --- Changing it ----------------------------------------------------------

  Future<void> _pending = Future.value();

  /// `colorThemeSequencer`: one change at a time, in order.
  Future<T> _queue<T>(Future<T> Function() change) {
    final result = _pending.then((_) => change());
    _pending = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// `setColorTheme(settingsId, preview ? 'preview' : 'auto')`: shows the
  /// theme; unless [preview], keeps it as the setting and in storage.
  @override
  Future<void> setColorTheme(String settingsId, {bool preview = false}) {
    final request = ++_request;
    return _queue(
      () => _setColorTheme(settingsId, preview: preview, request: request),
    );
  }

  /// Drops the preview: the choice kept shows again, Auto at the system's
  /// appearance now.
  @override
  Future<void> restoreColorThemePreview() {
    final request = ++_request;
    _preview = null;
    return _queue(() => _loadCurrent(request, force: true));
  }

  /// The settings file changed (by hand, say): its theme and Auto shown,
  /// nothing written back.
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
      // The kept theme's type, for a fallback, even as a preview shows.
      if (revision == _preferenceRevision) {
        final theme = manifest.themeById(id);
        final data = _deletedThemes.contains(id)
            ? null
            : _customThemes[id] ??
                  (theme != null ? _themeData(theme) : _extensionThemes[id]);
        if (data != null) _committedType = data.type;
      }
      await _loadCurrent(request, force: true);
    });
  }

  /// The system's appearance changed to [brightness]: shown under Auto
  /// (through [transition]), noted otherwise.
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

  /// A theme shown as the system's appearance changed, not as one was
  /// picked: what [transition] is for. One picked, or previewed (moving
  /// through the picker), shows at once.
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
              ? _preferredLightThemeId
              : _preferredDarkThemeId)
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
    // Kept, whatever previews since; not over settings changed meanwhile.
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

  /// [WorkbenchThemeService.instance] when null.
  final WorkbenchThemeService? service;

  /// What else restyles everything (the code's font), read as widgets
  /// build without depending on it.
  final Listenable? restyle;

  final WidgetBuilder builder;

  /// Counts the times everything was restyled (a color theme, the code's
  /// font): what a widget keeping what it built (read from the theme's
  /// colors without depending on them) builds anew on.
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
    // Painters may keep the colors they were made with.
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
