import 'dart:async';

import 'package:bao_editor/monaco/flutter/editor_document_model.dart';
import 'package:bao_editor/monaco/flutter/editor_surface_controller.dart';
import 'package:bao_editor/monaco/vs/platform/theme/common/theme.dart';
import 'package:bao_editor/monaco/vs/workbench/services/themes/common/color_theme_data.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart' hide ColorScheme;

import '../../chat/chat_keys.dart';
import '../../chat/chat_width.dart';
import '../../chat/edit_detail.dart';
import '../../chat/reply_scroll.dart';
import '../../chat/user_message_style.dart';
import '../../chat/widgets/chat_minimap.dart';
import '../../chat/widgets/pixel_loader.dart';
import '../../ide/editor_minimap_setting.dart';
import '../../ide/editor_word_wrap.dart';
import '../../ide/ide_code_editor.dart';
import '../../ide/ide_color_theme_picker.dart';
import '../../ide/ide_quick_input.dart' show ideLocaleCompare;
import '../../ide/terminal/terminal_colors.dart' show terminalColorTheme;
import '../../ide/terminal/terminal_render_theme.dart'
    show terminalBaseFontSize, vscodeTerminalFontSize;
import '../../ide/ide_menu.dart';
import '../../sidebar/sidebar_times.dart';
import '../../l10n/l10n.dart';
import '../../platform/event_log.dart' show appEvent;
import '../../theme/app_theme.dart';
import '../../theme/code_font.dart';
import '../../theme/window_blur.dart';
import '../../workspace/islands.dart';
import '../../theme/workbench_theme.dart'
    show
        ThemePaletteOverrides,
        ThemeSettingDefaults,
        WorkbenchColors,
        WorkbenchThemeService,
        themeColors;
import '../user_settings.dart';
import 'settings_dropdown.dart';
import 'settings_widgets.dart';

/// Settings → Appearance: the color theme (`workbench.colorTheme`, as
/// Preferences: Color Theme picks it), the chat's, the IDE's and the
/// terminal's alike, and how wide the conversation grows
/// (`chat.maxWidth`, see [ChatWidth]); how a file edit shows
/// ([EditDetail]); what an agent and a subagent show
/// running (see [PixelLoaderRole]); whether the sidebar's agents show
/// their times ([SidebarTimes]), whether the windows are blurred
/// underneath ([WindowBlur]); then the code's font, size and
/// ligatures, whether the editors wrap long lines ([EditorWordWrap]) and
/// show their minimap ([EditorMinimap]), the window's text size and the
/// terminal's (see [CodeFont]). A choice is applied and kept at once.
class AppearanceSettingsPage extends StatelessWidget {
  const AppearanceSettingsPage({
    super.key,
    required this.themes,
    this.changes,
    this.settings,
  });

  final IdeColorThemeController themes;

  /// Tells when [themes]' theme changes (the theme service itself).
  final Listenable? changes;

  /// settings.json; none under test, where the width is not kept.
  final UserSettings? settings;

  static String widthName(BuildContext context, double width) {
    final l10n = context.l10n;
    if (width.isInfinite) return l10n.appearanceSettingsChatWidthFull;
    if (width == ChatWidth.fallback) {
      return l10n.appearanceSettingsChatWidthDefault;
    }
    return '${width.round()}';
  }

  void _selectWidth(double width) {
    ChatWidth.current.value = width;
    final settings = this.settings;
    if (settings == null) return;
    unawaited(
      settings
          .update(ChatWidth.settingKey, ChatWidth.setting(width))
          .catchError((Object error) {
            // A settings file that does not parse is left as it is; its
            // error is shown.
            debugPrint('${ChatWidth.settingKey} not kept: $error');
          }),
    );
  }

  /// The themes in the menu: light, dark, then high contrast, as the
  /// picker lists them, each group the defaults first, then by label.
  List<List<IdeColorThemeEntry>> _groups() {
    final all = themes.colorThemes;
    int pinRank(IdeColorThemeEntry theme) => switch (theme.id) {
      'Antigravity Light' => -1,
      ThemeSettingDefaults.colorThemeLight ||
      ThemeSettingDefaults.colorThemeDark => 0,
      'Claude Code Light' || 'Claude Code Dark' => 1,
      _ => 2,
    };
    List<IdeColorThemeEntry> sorted(bool Function(ColorScheme) type) =>
        all.where((theme) => type(theme.type)).toList()..sort((a, b) {
          final pin = pinRank(a) - pinRank(b);
          return pin != 0 ? pin : ideLocaleCompare(a.label, b.label);
        });
    return [
      sorted((type) => type == ColorScheme.light),
      sorted((type) => type == ColorScheme.dark),
      sorted(isHighContrast),
    ];
  }

  void _select(String id) => unawaited(
    themes.setColorTheme(id).catchError((Object error) {
      debugPrint('$id not applied: $error');
    }),
  );

  /// The families the dropdown offers: each is put first, then the defaults.
  static const _codeFontPresets = <String>[
    'JetBrains Mono',
    'Fira Code',
    'Cascadia Code',
    'Consolas',
    'Menlo',
    'Monaco',
    'Courier New',
  ];

  /// The step of [steps] nearest [value]: the slider's position.
  static int _nearest<T extends num>(List<T> steps, num value) {
    var nearest = 0;
    for (var i = 1; i < steps.length; i++) {
      if ((steps[i] - value).abs() < (steps[nearest] - value).abs()) {
        nearest = i;
      }
    }
    return nearest;
  }

  static List<String> _presetOf(String name) => [
    name,
    ...CodeFont.defaultFamilies.where((family) => family != name),
  ];

  /// The dropdown's text for [families]: Default; a preset's name when the
  /// list is that preset; else the list itself.
  static String _familyName(BuildContext context, List<String> families) {
    if (listEquals(families, CodeFont.defaultFamilies)) {
      return context.l10n.appearanceSettingsCodeFontDefault;
    }
    final first = families.first;
    if (listEquals(families, _presetOf(first))) return first;
    return families.join(', ');
  }

  /// Writes [value] for [key] in settings.json (null removes it).
  void _keep(String key, Object? value) {
    final settings = this.settings;
    if (settings == null) return;
    unawaited(
      settings.update(key, value).catchError((Object error) {
        // A settings file that does not parse is left as it is; its error
        // is shown.
        debugPrint('$key not kept: $error');
      }),
    );
  }

  static String _styleName(BuildContext context, UserMessageStyle style) =>
      switch (style) {
        UserMessageStyle.sticky =>
          context.l10n.appearanceSettingsUserMessageStyleSticky,
        UserMessageStyle.bubble =>
          context.l10n.appearanceSettingsUserMessageStyleBubble,
      };

  void _selectStyle(UserMessageStyle style) {
    UserMessageStyle.current.value = style;
    _keep(UserMessageStyle.settingKey, style.setting);
  }

  static String _editDetailName(BuildContext context, EditDetail detail) =>
      switch (detail) {
        EditDetail.card => context.l10n.appearanceSettingsEditDetailCard,
        EditDetail.compact => context.l10n.appearanceSettingsEditDetailCompact,
      };

  void _selectEditDetail(EditDetail detail) {
    EditDetail.current.value = detail;
    _keep(EditDetail.settingKey, detail.setting);
  }

  static String _replyScrollName(BuildContext context, ReplyScroll choice) =>
      switch (choice) {
        ReplyScroll.follow => context.l10n.appearanceSettingsReplyScrollFollow,
        ReplyScroll.start => context.l10n.appearanceSettingsReplyScrollStart,
      };

  void _selectReplyScroll(ReplyScroll choice) {
    ReplyScroll.current.value = choice;
    _keep(ReplyScroll.settingKey, choice.setting);
  }

  void _selectMinimap(bool on) {
    ChatMinimap.enabled.value = on;
    _keep(ChatMinimap.settingKey, ChatMinimap.setting(on));
  }

  void _selectMinimapGlass(double opacity) {
    ChatMinimap.glass.value = opacity;
    _keep(ChatMinimap.glassKey, ChatMinimap.glassSetting(opacity));
  }

  void _selectMinimapElasticity(ChatMinimapElasticity level) {
    ChatMinimap.elasticity.value = level;
    _keep(ChatMinimap.elasticityKey, ChatMinimap.elasticitySetting(level));
  }

  void _selectWindowBlur(bool on) {
    WindowBlur.enabled.value = on;
    _keep(WindowBlur.settingKey, WindowBlur.setting(on));
  }

  void _selectSidebarTimes(bool on) {
    SidebarTimes.shown.value = on;
    _keep(SidebarTimes.settingKey, SidebarTimes.setting(on));
  }

  static String _islandsName(BuildContext context, bool islands) {
    final isZh = Localizations.maybeLocaleOf(context)?.languageCode == 'zh';
    if (isZh) {
      return islands ? '样式 1 · 悬浮岛屿卡片' : '样式 2 · 极简分割线';
    }
    return islands ? 'Style 1 · Floating Cards' : 'Style 2 · Flush Borders';
  }

  void _selectIslands(bool on) {
    Islands.enabled.value = on;
    _keep(Islands.settingKey, Islands.setting(on));
  }

  static String elasticityName(
    BuildContext context,
    ChatMinimapElasticity level,
  ) => switch (level) {
    ChatMinimapElasticity.off => context.l10n.minimapElasticityOff,
    ChatMinimapElasticity.subtle => context.l10n.minimapElasticitySubtle,
    ChatMinimapElasticity.medium => context.l10n.minimapElasticityMedium,
    ChatMinimapElasticity.bouncy => context.l10n.minimapElasticityBouncy,
  };

  static String loaderStyleName(BuildContext context, PixelLoaderStyle style) {
    final isZh = Localizations.maybeLocaleOf(context)?.languageCode == 'zh';
    if (isZh) {
      return switch (style) {
        PixelLoaderStyle.fill => '波浪律动（默认 · App 图标）',
        PixelLoaderStyle.equalizer => '音律均衡（频谱高低交错）',
        PixelLoaderStyle.pulse => '双拍心跳（主橙柱领跳脉冲）',
        PixelLoaderStyle.ripple => '涟漪扩散（由左向右依次弹起）',
        PixelLoaderStyle.rain => '交替跃动（奇偶双柱反相跳动）',
        PixelLoaderStyle.breathe => '同频呼吸（保持图标黄金比例）',
        PixelLoaderStyle.snake => '回旋追逐（波峰左右往返）',
        PixelLoaderStyle.stack => '阶梯蓄力（逐级攀升后回落）',
        PixelLoaderStyle.twinkle => '灵动闪烁（错落韵律跳跃）',
        PixelLoaderStyle.checker => '对称共振（内外双柱交替）',
        PixelLoaderStyle.bar => '单柱领跑（四柱轮流冲顶）',
        PixelLoaderStyle.sweep => '顺滑扫掠（斜向波浪推进）',
        PixelLoaderStyle.scan => '极速音轨（高频律动跳动）',
        PixelLoaderStyle.hourglass => '潮汐涨落（慢起快落律动）',
        PixelLoaderStyle.spinner => '顺向波浪',
        PixelLoaderStyle.twinSpinner => '双峰并进',
        PixelLoaderStyle.corners => '两端呼应',
        PixelLoaderStyle.dots => '轻盈点跃',
        PixelLoaderStyle.circle => context.l10n.loaderStyleCircle,
      };
    }
    final l10n = context.l10n;
    return switch (style) {
      PixelLoaderStyle.snake => l10n.loaderStyleSnake,
      PixelLoaderStyle.stack => l10n.loaderStyleStack,
      PixelLoaderStyle.twinkle => l10n.loaderStyleTwinkle,
      PixelLoaderStyle.fill => l10n.loaderStyleFill,
      PixelLoaderStyle.pulse => l10n.loaderStylePulse,
      PixelLoaderStyle.ripple => l10n.loaderStyleRipple,
      PixelLoaderStyle.sweep => l10n.loaderStyleSweep,
      PixelLoaderStyle.rain => l10n.loaderStyleRain,
      PixelLoaderStyle.checker => l10n.loaderStyleChecker,
      PixelLoaderStyle.spinner => l10n.loaderStyleSpinner,
      PixelLoaderStyle.twinSpinner => l10n.loaderStyleTwinSpinner,
      PixelLoaderStyle.corners => l10n.loaderStyleCorners,
      PixelLoaderStyle.dots => l10n.loaderStyleDots,
      PixelLoaderStyle.equalizer => l10n.loaderStyleEqualizer,
      PixelLoaderStyle.bar => l10n.loaderStyleBar,
      PixelLoaderStyle.scan => l10n.loaderStyleScan,
      PixelLoaderStyle.hourglass => l10n.loaderStyleHourglass,
      PixelLoaderStyle.breathe => l10n.loaderStyleBreathe,
      PixelLoaderStyle.circle => l10n.loaderStyleCircle,
    };
  }

  void _selectLoader(PixelLoaderRole role, PixelLoaderStyle style) {
    role.style.value = style;
    _keep(role.styleKey, style.setting);
  }

  void _selectLoaderSpeed(PixelLoaderRole role, double speed) {
    role.speed.value = speed;
    _keep(role.speedKey, role.speedSetting(speed));
  }

  /// 1×, 1.5×: the pace as the slider says it.
  static String speedName(double speed) =>
      '${speed == speed.roundToDouble() ? speed.round() : speed}×';

  /// [role]'s rows: its style playing, then the menu of them (those made
  /// for work going on, the plainer ones, the ring there was before); under
  /// it, its pace, but for the ring, which keeps its own.
  List<Widget> _loaderRows(
    BuildContext context,
    PixelLoaderRole role, {
    required String label,
    required String description,
  }) {
    final current = role.style.value;
    final shown = loaderStyleName(context, current);
    final speed = role.speed.value;
    final speedShown = speedName(speed);
    return [
      SettingsRow(
        label: label,
        description: description,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            PixelLoader.preview(current, role: role, size: 16),
            const SizedBox(width: 12),
            SettingsDropdown(
              current: shown,
              width: 180,
              semanticLabel: context.l10n.appearanceSettingsLoaderLabel(
                label,
                shown,
              ),
              entries: () => ideMenuGroups([
                for (final group in [
                  PixelLoaderStyle.forSubagents,
                  [
                    for (final style in PixelLoaderStyle.values)
                      if (!PixelLoaderStyle.forSubagents.contains(style) &&
                          style != PixelLoaderStyle.circle)
                        style,
                  ],
                  [PixelLoaderStyle.circle],
                ])
                  [
                    for (final style in group)
                      IdeMenuAction(
                        loaderStyleName(context, style),
                        checked: style == current,
                        onSelected: () => _selectLoader(role, style),
                      ),
                  ],
              ]),
            ),
          ],
        ),
      ),
      if (current != PixelLoaderStyle.circle)
        SettingsRow(
          label: context.l10n.appearanceSettingsLoaderSpeed,
          trailing: SettingsSlider(
            step: PixelLoaderRole.speeds.indexOf(speed),
            count: PixelLoaderRole.speeds.length,
            label: speedShown,
            semanticLabel: context.l10n.appearanceSettingsLoaderSpeedLabel(
              label,
              speedShown,
            ),
            onChanged: (step) =>
                _selectLoaderSpeed(role, PixelLoaderRole.speeds[step]),
          ),
        ),
    ];
  }

  void _selectFamilies(List<String> families) {
    CodeFont.families.value = families;
    _keep(CodeFont.familySettingKey, CodeFont.familiesSetting(families));
  }

  void _selectSize(double size) {
    CodeFont.size.value = size;
    _keep(CodeFont.sizeSettingKey, CodeFont.sizeSetting(size));
  }

  void _selectLigatures(bool on) {
    CodeFont.ligatures.value = on;
    _keep(CodeFont.ligaturesSettingKey, CodeFont.ligaturesSetting(on));
  }

  void _selectTerminalSize(double? size) {
    CodeFont.terminalSize.value = size;
    _keep(CodeFont.terminalSizeSettingKey, CodeFont.terminalSizeSetting(size));
  }

  /// The step nearest the size the terminal follows the window's text at,
  /// where a custom size starts.
  static double _followedTerminalSize() {
    final size =
        CodeFont.uiSized(terminalBaseFontSize) * CodeFont.uiScale.value / 100;
    return CodeFont.sizeSteps[_nearest(CodeFont.sizeSteps, size)];
  }

  void _selectUiScale(int percent) {
    appEvent('zoom', 'Interface Size set');
    CodeFont.uiScale.value = percent;
    _keep(CodeFont.uiScaleSettingKey, CodeFont.uiScaleSetting(percent));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListenableBuilder(
      listenable: Listenable.merge([
        changes,
        ChatWidth.current,
        UserMessageStyle.current,
        EditDetail.current,
        ReplyScroll.current,
        ChatMinimap.enabled,
        ChatMinimap.glass,
        ChatMinimap.elasticity,
        SidebarTimes.shown,
        WindowBlur.enabled,
        Islands.enabled,
        for (final role in PixelLoaderRole.values) ...[role.style, role.speed],
        CodeFont.families,
        CodeFont.size,
        CodeFont.ligatures,
        CodeFont.uiScale,
        CodeFont.terminalSize,
        EditorWordWrap.on,
        EditorMinimap.on,
        ThemePaletteOverrides.changes,
      ]),
      builder: (context, _) {
        final widthStep = ChatWidth.stepOf(ChatWidth.current.value);
        final widthShown = widthName(context, ChatWidth.steps[widthStep]);
        final styleShown = _styleName(context, UserMessageStyle.current.value);
        final editDetailShown = _editDetailName(
          context,
          EditDetail.current.value,
        );
        final replyScrollShown = _replyScrollName(
          context,
          ReplyScroll.current.value,
        );
        final glass = ChatMinimap.glass.value;
        final glassShown = '${(glass * 100).round()}%';
        final elasticityShown = elasticityName(
          context,
          ChatMinimap.elasticity.value,
        );
        final families = CodeFont.families.value;
        final sizeStep = _nearest(CodeFont.sizeSteps, CodeFont.size.value);
        final sizeShown = '${CodeFont.size.value.round()}';
        final uiScaleStep = CodeFont.uiScale.value - CodeFont.minUiScale;
        final uiScaleShown = '${CodeFont.uiScale.value}';
        final terminalSize = CodeFont.terminalSize.value;
        final terminalSizeShown = terminalSize == null
            ? l10n.appearanceSettingsTerminalSizeFollow
            : l10n.appearanceSettingsTerminalSizeCustom;
        final groups = _groups();
        final currentId = themes.colorThemeId;
        final current = groups
            .expand((group) => group)
            .where((theme) => theme.id == currentId)
            .firstOrNull;
        final shown = currentId == IdeColorThemeController.autoId
            ? l10n.themeAuto
            : current?.label ?? currentId;
        final key = ChatKeys.keyLabel(ideSelectColorThemeCommandId);
        final isZh = Localizations.maybeLocaleOf(context)?.languageCode == 'zh';
        final islandsOn = Islands.enabled.value;
        final islandsShown = _islandsName(context, islandsOn);
        return SettingsPage(
          title: l10n.appearanceSettingsTitle,
          children: [
            SettingsCard(
              children: [
                SettingsRow(
                  label: l10n.appearanceSettingsColorTheme,
                  description: key == null
                      ? l10n.appearanceSettingsColorThemeDescription
                      : l10n.appearanceSettingsColorThemeDescriptionWithKey(
                          key,
                        ),
                  trailing: SettingsDropdown(
                    current: shown,
                    width: 220,
                    semanticLabel: l10n.appearanceSettingsColorThemeLabel(
                      shown,
                    ),
                    entries: () => ideMenuGroups([
                      [
                        IdeMenuAction(
                          l10n.themeAuto,
                          keybinding: l10n.themeFollowSystem,
                          checked: currentId == IdeColorThemeController.autoId,
                          onSelected: () =>
                              _select(IdeColorThemeController.autoId),
                        ),
                      ],
                      for (final group in groups)
                        [
                          for (final theme in group)
                            IdeMenuAction(
                              theme.label,
                              checked: theme.id == currentId,
                              onSelected: () => _select(theme.id),
                            ),
                        ],
                    ]),
                  ),
                ),
                SettingsRow(
                  label: isZh ? '分区样式' : 'Partition Style',
                  description: isZh
                      ? '样式 1 采用悬浮圆角卡片与间距分区；样式 2 采用极简 1px 贯穿分割线分区'
                      : 'Choose between floating rounded cards (Style 1) or flush 1px border dividers (Style 2)',
                  trailing: SettingsDropdown(
                    current: islandsShown,
                    width: 220,
                    semanticLabel: islandsShown,
                    entries: () => ideMenuGroups([
                      [
                        for (final on in [true, false])
                          IdeMenuAction(
                            _islandsName(context, on),
                            checked: on == islandsOn,
                            onSelected: () => _selectIslands(on),
                          ),
                      ],
                    ]),
                  ),
                ),
                SettingsRow(
                  label: l10n.appearanceSettingsChatWidth,
                  description: l10n.appearanceSettingsChatWidthDescription,
                  trailing: SettingsSlider(
                    step: widthStep,
                    count: ChatWidth.steps.length,
                    label: widthShown,
                    semanticLabel: l10n.appearanceSettingsChatWidthLabel(
                      widthShown,
                    ),
                    onChanged: (step) => _selectWidth(ChatWidth.steps[step]),
                    tapOnly: true,
                  ),
                ),
                SettingsRow(
                  label: l10n.appearanceSettingsUserMessageStyle,
                  description:
                      l10n.appearanceSettingsUserMessageStyleDescription,
                  trailing: SettingsDropdown(
                    current: styleShown,
                    width: 220,
                    semanticLabel: l10n.appearanceSettingsUserMessageStyleLabel(
                      styleShown,
                    ),
                    entries: () => ideMenuGroups([
                      [
                        for (final style in UserMessageStyle.values)
                          IdeMenuAction(
                            _styleName(context, style),
                            checked: style == UserMessageStyle.current.value,
                            onSelected: () => _selectStyle(style),
                          ),
                      ],
                    ]),
                  ),
                ),
                SettingsRow(
                  label: l10n.appearanceSettingsEditDetail,
                  description: l10n.appearanceSettingsEditDetailDescription,
                  trailing: SettingsDropdown(
                    current: editDetailShown,
                    width: 220,
                    semanticLabel: l10n.appearanceSettingsEditDetailLabel(
                      editDetailShown,
                    ),
                    entries: () => ideMenuGroups([
                      [
                        for (final detail in EditDetail.values)
                          IdeMenuAction(
                            _editDetailName(context, detail),
                            checked: detail == EditDetail.current.value,
                            onSelected: () => _selectEditDetail(detail),
                          ),
                      ],
                    ]),
                  ),
                ),
                SettingsRow(
                  label: l10n.appearanceSettingsReplyScroll,
                  description: l10n.appearanceSettingsReplyScrollDescription,
                  trailing: SettingsDropdown(
                    current: replyScrollShown,
                    width: 220,
                    semanticLabel: l10n.appearanceSettingsReplyScrollLabel(
                      replyScrollShown,
                    ),
                    entries: () => ideMenuGroups([
                      [
                        for (final choice in ReplyScroll.values)
                          IdeMenuAction(
                            _replyScrollName(context, choice),
                            checked: choice == ReplyScroll.current.value,
                            onSelected: () => _selectReplyScroll(choice),
                          ),
                      ],
                    ]),
                  ),
                ),
                SettingsSwitchRow(
                  label: l10n.appearanceSettingsMinimap,
                  description: l10n.appearanceSettingsMinimapDescription,
                  value: ChatMinimap.enabled.value,
                  onChanged: _selectMinimap,
                ),
                if (ChatMinimap.enabled.value)
                  SettingsRow(
                    label: l10n.appearanceSettingsMinimapGlass,
                    description: l10n.appearanceSettingsMinimapGlassDescription,
                    trailing: SettingsSlider(
                      step: ChatMinimap.glassSteps.indexOf(glass),
                      count: ChatMinimap.glassSteps.length,
                      label: glassShown,
                      semanticLabel: l10n.appearanceSettingsMinimapGlassLabel(
                        glassShown,
                      ),
                      onChanged: (step) =>
                          _selectMinimapGlass(ChatMinimap.glassSteps[step]),
                    ),
                  ),
                if (ChatMinimap.enabled.value)
                  SettingsRow(
                    label: l10n.appearanceSettingsMinimapElasticity,
                    description:
                        l10n.appearanceSettingsMinimapElasticityDescription,
                    trailing: SettingsSlider(
                      step: ChatMinimap.elasticity.value.index,
                      count: ChatMinimapElasticity.values.length,
                      label: elasticityShown,
                      semanticLabel: l10n
                          .appearanceSettingsMinimapElasticityLabel(
                            elasticityShown,
                          ),
                      onChanged: (step) => _selectMinimapElasticity(
                        ChatMinimapElasticity.values[step],
                      ),
                    ),
                  ),
              ],
            ),
            _ThemePaletteSection(
              dark: false,
              themes: themes,
              entries: groups.first,
              onSelectPreset: _select,
            ),
            _ThemePaletteSection(
              dark: true,
              themes: themes,
              entries: groups.length > 1 ? groups[1] : const [],
              onSelectPreset: _select,
            ),
            SettingsCard(
              children: [
                ..._loaderRows(
                  context,
                  PixelLoaderRole.agent,
                  label: l10n.appearanceSettingsAgentLoader,
                  description: l10n.appearanceSettingsAgentLoaderDescription,
                ),
                ..._loaderRows(
                  context,
                  PixelLoaderRole.subagent,
                  label: l10n.appearanceSettingsSubagentLoader,
                  description: l10n.appearanceSettingsSubagentLoaderDescription,
                ),
              ],
            ),
            SettingsCard(
              children: [
                if (WindowBlur.available)
                  SettingsSwitchRow(
                    label: l10n.appearanceSettingsWindowBlur,
                    description: l10n.appearanceSettingsWindowBlurDescription,
                    value: WindowBlur.enabled.value,
                    onChanged: _selectWindowBlur,
                  ),
                SettingsSwitchRow(
                  label: l10n.appearanceSettingsSidebarTimes,
                  description: l10n.appearanceSettingsSidebarTimesDescription,
                  value: SidebarTimes.shown.value,
                  onChanged: _selectSidebarTimes,
                ),
              ],
            ),
            SettingsCard(
              children: [
                SettingsRow(
                  label: l10n.appearanceSettingsCodeFont,
                  description: l10n.appearanceSettingsCodeFontDescription,
                  below: [
                    SettingsTextField(
                      value: listEquals(families, CodeFont.defaultFamilies)
                          ? ''
                          : families.join(', '),
                      hint: CodeFont.defaultFamilies.join(', '),
                      semanticLabel: l10n.appearanceSettingsCodeFontField,
                      width: 360,
                      onSubmitted: (text) =>
                          _selectFamilies(CodeFont.parseFamilies(text)),
                    ),
                  ],
                  trailing: SettingsDropdown(
                    current: _familyName(context, families),
                    width: 220,
                    semanticLabel: l10n.appearanceSettingsCodeFontLabel(
                      _familyName(context, families),
                    ),
                    entries: () => ideMenuGroups([
                      [
                        IdeMenuAction(
                          l10n.appearanceSettingsCodeFontDefault,
                          checked: listEquals(
                            families,
                            CodeFont.defaultFamilies,
                          ),
                          onSelected: () =>
                              _selectFamilies(CodeFont.defaultFamilies),
                        ),
                        for (final name in _codeFontPresets)
                          IdeMenuAction(
                            name,
                            checked: listEquals(families, _presetOf(name)),
                            onSelected: () => _selectFamilies(_presetOf(name)),
                          ),
                      ],
                    ]),
                  ),
                ),
                // Not const: it must redraw as the font, size or ligatures
                // change.
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: _CodeFontPreview(),
                ),
                SettingsRow(
                  label: l10n.appearanceSettingsCodeSize,
                  description: l10n.appearanceSettingsCodeSizeDescription,
                  trailing: SettingsSlider(
                    step: sizeStep,
                    count: CodeFont.sizeSteps.length,
                    label: sizeShown,
                    semanticLabel: l10n.appearanceSettingsCodeSizeLabel(
                      sizeShown,
                    ),
                    onChanged: (step) => _selectSize(CodeFont.sizeSteps[step]),
                  ),
                ),
                SettingsSwitchRow(
                  label: l10n.appearanceSettingsLigatures,
                  description: l10n.appearanceSettingsLigaturesDescription,
                  value: CodeFont.ligatures.value,
                  onChanged: _selectLigatures,
                ),
                SettingsSwitchRow(
                  label: l10n.appearanceSettingsWordWrap,
                  description: l10n.appearanceSettingsWordWrapDescription,
                  value: EditorWordWrap.on.value,
                  onChanged: EditorWordWrap.set,
                ),
                SettingsSwitchRow(
                  label: l10n.appearanceSettingsCodeMinimap,
                  description: l10n.appearanceSettingsCodeMinimapDescription,
                  value: EditorMinimap.on.value,
                  onChanged: EditorMinimap.set,
                ),
                SettingsRow(
                  label: l10n.appearanceSettingsUiScale,
                  description: l10n.appearanceSettingsUiScaleDescription,
                  trailing: SettingsSlider(
                    step: uiScaleStep,
                    count: CodeFont.maxUiScale - CodeFont.minUiScale + 1,
                    label: '$uiScaleShown%',
                    semanticLabel: l10n.appearanceSettingsUiScaleLabel(
                      uiScaleShown,
                    ),
                    onChanged: (step) =>
                        _selectUiScale(CodeFont.minUiScale + step),
                  ),
                ),
                SettingsRow(
                  label: l10n.appearanceSettingsTerminalSize,
                  description: l10n.appearanceSettingsTerminalSizeDescription,
                  trailing: SettingsDropdown(
                    current: terminalSizeShown,
                    width: 220,
                    semanticLabel: l10n.appearanceSettingsTerminalSizeLabel(
                      terminalSizeShown,
                    ),
                    entries: () => ideMenuGroups([
                      [
                        IdeMenuAction(
                          l10n.appearanceSettingsTerminalSizeFollow,
                          checked: terminalSize == null,
                          onSelected: () => _selectTerminalSize(null),
                        ),
                        IdeMenuAction(
                          l10n.appearanceSettingsTerminalSizeCustom,
                          checked: terminalSize != null,
                          onSelected: () {
                            if (terminalSize != null) return;
                            _selectTerminalSize(_followedTerminalSize());
                          },
                        ),
                      ],
                    ]),
                  ),
                ),
                if (terminalSize != null)
                  SettingsRow(
                    label: l10n.appearanceSettingsTerminalSizeValue,
                    trailing: SettingsSlider(
                      step: _nearest(CodeFont.sizeSteps, terminalSize),
                      count: CodeFont.sizeSteps.length,
                      label: '${terminalSize.round()}',
                      semanticLabel: l10n.appearanceSettingsTerminalSizeLabel(
                        '${terminalSize.round()}',
                      ),
                      onChanged: (step) =>
                          _selectTerminalSize(CodeFont.sizeSteps[step]),
                    ),
                  ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: _TerminalFontPreview(),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// A shell session in the terminal's colors, drawn as the terminal draws
/// text (its font, without ligatures, at its size), so the size can be seen
/// before a terminal is opened.
class _TerminalFontPreview extends StatelessWidget {
  const _TerminalFontPreview();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        terminalColorTheme,
        CodeFont.families,
        CodeFont.terminalSize,
      ]),
      builder: (context, _) {
        final colors = terminalColorTheme.value;
        final ansi = colors.ansi;
        // Scaled here as the terminal scales it, so not again by the text.
        final size = vscodeTerminalFontSize(
          MediaQuery.textScalerOf(context),
          SystemTextScale.maybeOf(context),
        );
        TextSpan span(String text, [Color? color]) => TextSpan(
          text: text,
          style: TextStyle(color: color),
        );
        List<TextSpan> prompt(String command) => [
          span('~/app ', ansi[4]),
          span('main ', ansi[5]),
          span('❯ ', ansi[2]),
          span('$command\n'),
        ];
        return DecoratedBox(
          decoration: BoxDecoration(
            color: colors.background,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.partBorder),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text.rich(
              TextSpan(
                children: [
                  ...prompt('ls'),
                  span('README.md  '),
                  span('lib', ansi[12]),
                  span('  pubspec.yaml  '),
                  span('test', ansi[12]),
                  span('\n'),
                  ...prompt('git status -s'),
                  span(' M', ansi[1]),
                  span(' lib/main.dart\n'),
                  span('??', ansi[1]),
                  span(' lib/terminal.dart'),
                ],
              ),
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                color: colors.foreground,
                fontFamily: AppFonts.mono,
                fontFamilyFallback: AppFonts.monoFallbacks,
                fontSize: size,
                height: 1.2,
                // The terminal draws a cell at a time: no ligatures.
                fontFeatures: const [
                  FontFeature.disable('liga'),
                  FontFeature.disable('calt'),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A sample of TypeScript in the IDE's editor, highlighted, read-only: it is
/// drawn in the code font as it is set (family, size, ligatures), so the
/// choice can be seen before it is used.
class _CodeFontPreview extends StatefulWidget {
  const _CodeFontPreview();

  @override
  State<_CodeFontPreview> createState() => _CodeFontPreviewState();
}

class _CodeFontPreviewState extends State<_CodeFontPreview> {
  static const _sample = '''
type Point = { x: number; y: number };
const add = (a: Point, b: Point): Point =>
  ({ x: a.x + b.x, y: a.y + b.y });
if (add(p, q).x >= 0 && p !== q) {
  return items ?? [];
}''';

  // The document is handed in, so it is disposed here, not by the controller.
  final _document = EditorDocumentModel(_sample);
  late final _text = EditorSurfaceController(document: _document);

  @override
  void dispose() {
    _text.dispose();
    _document.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // As tall as the sample at the code's size, so there is nothing to scroll.
    final lines = '\n'.allMatches(_sample).length + 1;
    return SizedBox(
      height: lines * CodeFont.sized(13) * 1.45 + 16,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.partBorder),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: IdeCodeEditor(
            controller: _text,
            path: 'preview.ts',
            readOnly: true,
            bare: true,
          ),
        ),
      ),
    );
  }
}

/// Interactive Light Theme / Dark Theme palette studio with per-theme
/// color customization, live window preview, and Add / Rename / Reset / Delete
/// theme management.
class _ThemePaletteSection extends StatefulWidget {
  const _ThemePaletteSection({
    required this.dark,
    required this.themes,
    required this.entries,
    required this.onSelectPreset,
  });

  final bool dark;
  final IdeColorThemeController themes;
  final List<IdeColorThemeEntry> entries;
  final ValueChanged<String> onSelectPreset;

  @override
  State<_ThemePaletteSection> createState() => _ThemePaletteSectionState();
}

class _ThemePaletteSectionState extends State<_ThemePaletteSection> {
  String? _selectedId;
  ColorThemeData? _loadedData;
  String? _loadedDataId;

  WorkbenchThemeService? get _service => widget.themes is WorkbenchThemeService
      ? widget.themes as WorkbenchThemeService
      : null;

  String get _fallbackDefaultId => widget.dark
      ? ThemeSettingDefaults.colorThemeDark
      : ThemeSettingDefaults.colorThemeLight;

  @override
  void initState() {
    super.initState();
    _syncSelection(initial: true);
  }

  @override
  void didUpdateWidget(covariant _ThemePaletteSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    final activeChanged =
        oldWidget.themes.colorThemeId != widget.themes.colorThemeId;
    _syncSelection(forceFollowActive: activeChanged);
  }

  void _syncSelection({bool initial = false, bool forceFollowActive = false}) {
    final activeId = widget.themes.colorThemeId;
    final activeInGroup = widget.entries.any((e) => e.id == activeId);
    String nextId;
    if (activeInGroup && (initial || forceFollowActive || _selectedId == null)) {
      nextId = activeId;
    } else if (_selectedId != null &&
        widget.entries.any((e) => e.id == _selectedId)) {
      nextId = _selectedId!;
    } else if (activeInGroup) {
      nextId = activeId;
    } else if (widget.entries.any((e) => e.id == _fallbackDefaultId)) {
      nextId = _fallbackDefaultId;
    } else if (widget.entries.isNotEmpty) {
      nextId = widget.entries.first.id;
    } else {
      nextId = _fallbackDefaultId;
    }
    _selectedId = nextId;
    _ensureThemeLoaded(nextId);
  }

  void _ensureThemeLoaded(String id) {
    final service = _service;
    if (service == null) return;
    if (_loadedDataId == id && _loadedData != null) return;
    if (service.colorTheme.settingsId == id && service.colorTheme.isLoaded) {
      _loadedData = service.colorTheme;
      _loadedDataId = id;
      return;
    }
    unawaited(
      service.loadThemeData(id).then((data) {
        if (!mounted || _selectedId != id || data == null) return;
        setState(() {
          _loadedData = data;
          _loadedDataId = id;
        });
      }),
    );
  }

  Color? _rawThemeColor(String colorKey) {
    final data = _loadedDataId == _selectedId ? _loadedData : null;
    final raw = data?.getColor(colorKey);
    return raw == null ? null : WorkbenchColors.toFlutterColor(raw);
  }

  Color _baseSlotColor(String slot) => switch (slot) {
    ThemePaletteOverrides.slotBackground =>
      _rawThemeColor('editor.background') ??
          (widget.dark
              ? ThemePaletteOverrides.defaultDarkBackground
              : ThemePaletteOverrides.defaultLightBackground),
    ThemePaletteOverrides.slotSidebar =>
      _rawThemeColor('sideBar.background') ??
          (widget.dark ? const Color(0xFF161615) : const Color(0xFFEFEEEA)),
    ThemePaletteOverrides.slotCard =>
      _rawThemeColor('agentsChatInput.background') ??
          _rawThemeColor('editorWidget.background') ??
          (widget.dark ? const Color(0xFF252421) : const Color(0xFFFFFFFF)),
    ThemePaletteOverrides.slotForeground =>
      _rawThemeColor('foreground') ??
          (widget.dark
              ? ThemePaletteOverrides.defaultDarkForeground
              : ThemePaletteOverrides.defaultLightForeground),
    ThemePaletteOverrides.slotAccent =>
      _rawThemeColor('textLink.foreground') ??
          _rawThemeColor('button.background') ??
          (widget.dark
              ? ThemePaletteOverrides.defaultDarkAccent
              : ThemePaletteOverrides.defaultLightAccent),
    ThemePaletteOverrides.slotInlineCode =>
      _rawThemeColor('textPreformat.foreground') ??
          (widget.dark ? const Color(0xFFE599F7) : const Color(0xFF9E2825)),
    _ => const Color(0xFF888888),
  };

  Color _effectiveSlotColor(String themeId, String slot) =>
      ThemePaletteOverrides.slotColor(themeId, slot) ?? _baseSlotColor(slot);

  void _selectPreset(String id) {
    setState(() => _selectedId = id);
    _ensureThemeLoaded(id);
    widget.onSelectPreset(id);
  }

  Future<void> _promptCreateTheme(
    BuildContext context, {
    required bool isZh,
    required String baseId,
    required bool saveCurrentAsNew,
  }) async {
    final service = _service;
    if (service == null) return;
    final baseLabel =
        widget.entries.where((e) => e.id == baseId).firstOrNull?.label ?? baseId;
    final defaultName = saveCurrentAsNew
        ? (isZh ? '$baseLabel 副本' : '$baseLabel Copy')
        : (widget.dark
              ? (isZh ? '自定义深色主题' : 'Custom Dark')
              : (isZh ? '自定义浅色主题' : 'Custom Light'));
    final nameController = TextEditingController(text: defaultName);
    var selectedBase = baseId;
    var inheritEdits = saveCurrentAsNew || ThemePaletteOverrides.hasCustomFor(baseId);

    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: const Color(0x66000000),
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => Dialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: AppColors.border),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    saveCurrentAsNew
                        ? (isZh ? '另存当前配色为新主题' : 'Save Palette as New Theme')
                        : (isZh ? '新建主题' : 'Create New Theme'),
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    isZh ? '主题名称' : 'Theme Name',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: nameController,
                    autofocus: true,
                    style: TextStyle(color: AppColors.text, fontSize: 13),
                    decoration: _dialogInputDecoration(
                      hintText: isZh ? '输入新主题名称…' : 'Enter theme name…',
                    ),
                    onSubmitted: (_) => Navigator.pop(dialogContext, true),
                  ),
                  if (!saveCurrentAsNew && widget.entries.length > 1) ...[
                    const SizedBox(height: 12),
                    Text(
                      isZh ? '基础模板' : 'Base Preset',
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppColors.borderStrong),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: widget.entries.any((e) => e.id == selectedBase)
                              ? selectedBase
                              : widget.entries.first.id,
                          isExpanded: true,
                          dropdownColor: AppColors.surfaceRaised,
                          style: TextStyle(color: AppColors.text, fontSize: 13),
                          items: [
                            for (final entry in widget.entries)
                              DropdownMenuItem<String>(
                                value: entry.id,
                                child: Text(entry.label),
                              ),
                          ],
                          onChanged: (next) {
                            if (next == null) return;
                            setDialogState(() => selectedBase = next);
                          },
                        ),
                      ),
                    ),
                  ],
                  if (ThemePaletteOverrides.hasCustomFor(selectedBase)) ...[
                    const SizedBox(height: 10),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () =>
                          setDialogState(() => inheritEdits = !inheritEdits),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 18,
                            height: 18,
                            child: Checkbox(
                              value: inheritEdits,
                              onChanged: (v) => setDialogState(
                                () => inheritEdits = v ?? true,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              isZh
                                  ? '保留已修改的配色（并恢复原主题默认色）'
                                  : 'Include edited colors (and reset original preset)',
                              style: TextStyle(
                                color: AppColors.text,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      _DialogTextButton(
                        label: isZh ? '取消' : 'Cancel',
                        onTap: () => Navigator.pop(dialogContext, false),
                      ),
                      const SizedBox(width: 8),
                      _DialogPrimaryButton(
                        label: isZh ? '创建并应用' : 'Create & Apply',
                        onTap: () => Navigator.pop(dialogContext, true),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    final rawName = nameController.text;
    nameController.dispose();
    if (confirmed != true || !mounted) return;

    final slotsToBake = inheritEdits
        ? ThemePaletteOverrides.overridesFor(selectedBase)
        : const <String, Color>{};
    if (inheritEdits && ThemePaletteOverrides.hasCustomFor(selectedBase)) {
      await ThemePaletteOverrides.resetTheme(selectedBase);
    }
    final createdId = await service.createCustomTheme(
      name: rawName,
      dark: widget.dark,
      baseId: selectedBase,
      initialSlots: slotsToBake,
    );
    if (!mounted) return;
    setState(() {
      _selectedId = createdId;
      _loadedData = null;
      _loadedDataId = null;
    });
    _ensureThemeLoaded(createdId);
  }

  Future<void> _promptRenameTheme(
    BuildContext context, {
    required bool isZh,
    required String themeId,
  }) async {
    final service = _service;
    if (service == null || !service.isCustomTheme(themeId)) return;
    final controller = TextEditingController(text: themeId);
    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: const Color(0x66000000),
      builder: (dialogContext) => Dialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: AppColors.border),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isZh ? '重命名主题' : 'Rename Theme',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  autofocus: true,
                  style: TextStyle(color: AppColors.text, fontSize: 13),
                  decoration: _dialogInputDecoration(),
                  onSubmitted: (_) => Navigator.pop(dialogContext, true),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _DialogTextButton(
                      label: isZh ? '取消' : 'Cancel',
                      onTap: () => Navigator.pop(dialogContext, false),
                    ),
                    const SizedBox(width: 8),
                    _DialogPrimaryButton(
                      label: isZh ? '保存' : 'Save',
                      onTap: () => Navigator.pop(dialogContext, true),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final nextName = controller.text;
    controller.dispose();
    if (confirmed != true || !mounted) return;
    final renamedId = await service.renameCustomTheme(themeId, nextName);
    if (!mounted) return;
    setState(() {
      _selectedId = renamedId;
      _loadedData = null;
      _loadedDataId = null;
    });
    _ensureThemeLoaded(renamedId);
  }

  Future<void> _promptDeleteTheme(
    BuildContext context, {
    required bool isZh,
    required String themeId,
    required String label,
  }) async {
    final service = _service;
    if (service == null || widget.entries.length <= 1) return;
    final isCustom = service.isCustomTheme(themeId);
    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: const Color(0x66000000),
      builder: (dialogContext) => Dialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: AppColors.border),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 350),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isZh ? '删除主题「$label」？' : 'Delete "$label"?',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  isCustom
                      ? (isZh
                            ? '该自定义主题及其本地配色文件将被永久移除。'
                            : 'This custom theme and its local theme file will be permanently removed.')
                      : (isZh
                            ? '该内置主题将从主题列表中移除（后续可随时在菜单中恢复内置主题）。'
                            : 'This built-in theme will be removed from the list (you can restore built-in themes anytime from the menu).'),
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12.5,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _DialogTextButton(
                      label: isZh ? '取消' : 'Cancel',
                      onTap: () => Navigator.pop(dialogContext, false),
                    ),
                    const SizedBox(width: 8),
                    _DialogPrimaryButton(
                      label: isZh ? '删除' : 'Delete',
                      destructive: true,
                      onTap: () => Navigator.pop(dialogContext, true),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    await service.deleteTheme(themeId);
    if (!mounted) return;
    setState(() {
      _selectedId = null;
      _loadedData = null;
      _loadedDataId = null;
      _syncSelection();
    });
  }

  @override
  Widget build(BuildContext context) {
    final isZh = Localizations.maybeLocaleOf(context)?.languageCode == 'zh';
    final selectedId = _selectedId ?? _fallbackDefaultId;
    final selectedEntry = widget.entries
        .where((e) => e.id == selectedId)
        .firstOrNull;
    final presetLabel = selectedEntry?.label ?? selectedId;
    final hasCustomColors = ThemePaletteOverrides.hasCustomFor(selectedId);
    final service = _service;
    final isCustomTheme = service?.isCustomTheme(selectedId) ?? false;
    final canDelete = service != null && widget.entries.length > 1;
    final isActive = widget.themes.colorThemeId == selectedId;

    final slots = <({String slot, String label, String description})>[
      (
        slot: ThemePaletteOverrides.slotBackground,
        label: isZh ? '会话背景' : 'Background',
        description: isZh
            ? '右侧对话区与编辑器主画布底色'
            : 'Main conversation & editor canvas',
      ),
      (
        slot: ThemePaletteOverrides.slotSidebar,
        label: isZh ? '侧边栏背景' : 'Sidebar',
        description: isZh
            ? '左侧项目与会话导航栏底色'
            : 'Left project & conversation sidebar surface',
      ),
      (
        slot: ThemePaletteOverrides.slotCard,
        label: isZh ? '卡片与气泡' : 'Card & Bubble',
        description: isZh
            ? '输入框、用户消息气泡、选中卡片与菜单底色'
            : 'Composer, user message bubble, active row & menus',
      ),
      (
        slot: ThemePaletteOverrides.slotForeground,
        label: isZh ? '正文文字' : 'Foreground',
        description: isZh
            ? '主文本颜色（自动协调次级说明文字对比度）'
            : 'Primary text color with auto-harmonized muted text',
      ),
      (
        slot: ThemePaletteOverrides.slotAccent,
        label: isZh ? '强调色' : 'Accent',
        description: isZh
            ? '链接、焦点边框、徽标与交互高亮色'
            : 'Links, focus outlines, badges & primary actions',
      ),
      (
        slot: ThemePaletteOverrides.slotInlineCode,
        label: isZh ? '行内代码' : 'Inline Code',
        description: isZh
            ? 'Markdown 行内代码胶囊文字颜色'
            : 'Markdown inline code pill text color',
      ),
    ];

    return SettingsGroup(
      title: widget.dark
          ? (isZh ? '深色主题配色' : 'Dark Theme')
          : (isZh ? '浅色主题配色' : 'Light Theme'),
      children: [
        SettingsRow(
          label: isZh ? '预设主题' : 'Preset',
          description: isZh
              ? '可直接修改当前主题配色，或新建、重命名、删除主题'
              : 'Customize colors directly, or add, rename, and delete themes',
          trailing: _PalettePresetControl(
            isZh: isZh,
            selectedId: selectedId,
            label: presetLabel,
            isActive: isActive,
            isCustomTheme: isCustomTheme,
            hasCustomColors: hasCustomColors,
            canManage: service != null,
            canDelete: canDelete,
            hasDeletedBuiltins: service?.hasDeletedThemes ?? false,
            entries: [
              for (final entry in widget.entries)
                (
                  id: entry.id,
                  label: entry.label,
                  isCustom: service?.isCustomTheme(entry.id) ?? false,
                ),
            ],
            onSelected: _selectPreset,
            onApplyCurrent: () => _selectPreset(selectedId),
            onResetColors: () =>
                unawaited(ThemePaletteOverrides.resetTheme(selectedId)),
            onAddTheme: () => _promptCreateTheme(
              context,
              isZh: isZh,
              baseId: selectedId,
              saveCurrentAsNew: false,
            ),
            onSaveAsNewTheme: () => _promptCreateTheme(
              context,
              isZh: isZh,
              baseId: selectedId,
              saveCurrentAsNew: true,
            ),
            onRenameTheme: () => _promptRenameTheme(
              context,
              isZh: isZh,
              themeId: selectedId,
            ),
            onDeleteTheme: () => _promptDeleteTheme(
              context,
              isZh: isZh,
              themeId: selectedId,
              label: presetLabel,
            ),
            onRestoreBuiltins: () {
              if (service != null) {
                unawaited(service.restoreDeletedThemes());
              }
            },
          ),
        ),
        for (final item in slots)
          SettingsRow(
            label: item.label,
            description: item.description,
            trailing: _PaletteColorPill(
              isZh: isZh,
              dark: widget.dark,
              slot: item.slot,
              label: item.label,
              color: _effectiveSlotColor(selectedId, item.slot),
              defaultColor: _baseSlotColor(item.slot),
              customized:
                  ThemePaletteOverrides.slotColor(selectedId, item.slot) !=
                  null,
              onPreview: (color) {
                if (!isActive) {
                  widget.onSelectPreset(selectedId);
                }
                ThemePaletteOverrides.previewSlotColor(
                  selectedId,
                  item.slot,
                  color,
                );
              },
              onChanged: (color) {
                if (!isActive) {
                  widget.onSelectPreset(selectedId);
                }
                unawaited(
                  ThemePaletteOverrides.setSlotColor(
                    selectedId,
                    item.slot,
                    color,
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

InputDecoration _dialogInputDecoration({String? hintText, String? prefixText}) {
  return InputDecoration(
    hintText: hintText,
    hintStyle: TextStyle(color: AppColors.textFaint, fontSize: 12.5),
    prefixText: prefixText,
    prefixStyle: TextStyle(
      color: AppColors.textMuted,
      fontFamily: AppFonts.mono,
      fontSize: 13,
    ),
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: AppColors.borderStrong),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: AppColors.accent),
    ),
  );
}

class _DialogTextButton extends StatelessWidget {
  const _DialogTextButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text(
            label,
            style: TextStyle(color: AppColors.textMuted, fontSize: 12.5),
          ),
        ),
      ),
    );
  }
}

class _DialogPrimaryButton extends StatelessWidget {
  const _DialogPrimaryButton({
    required this.label,
    required this.onTap,
    this.destructive = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final bg = destructive ? const Color(0xFFDF4B44) : AppColors.accent;
    final fg = destructive
        ? const Color(0xFFFFFFFF)
        : themeColors['button.foreground'];
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: fg,
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class _PalettePresetControl extends StatefulWidget {
  const _PalettePresetControl({
    required this.isZh,
    required this.selectedId,
    required this.label,
    required this.isActive,
    required this.isCustomTheme,
    required this.hasCustomColors,
    required this.canManage,
    required this.canDelete,
    required this.hasDeletedBuiltins,
    required this.entries,
    required this.onSelected,
    required this.onApplyCurrent,
    required this.onResetColors,
    required this.onAddTheme,
    required this.onSaveAsNewTheme,
    required this.onRenameTheme,
    required this.onDeleteTheme,
    required this.onRestoreBuiltins,
  });

  final bool isZh;
  final String selectedId;
  final String label;
  final bool isActive;
  final bool isCustomTheme;
  final bool hasCustomColors;
  final bool canManage;
  final bool canDelete;
  final bool hasDeletedBuiltins;
  final List<({String id, String label, bool isCustom})> entries;
  final ValueChanged<String> onSelected;
  final VoidCallback onApplyCurrent;
  final VoidCallback onResetColors;
  final VoidCallback onAddTheme;
  final VoidCallback onSaveAsNewTheme;
  final VoidCallback onRenameTheme;
  final VoidCallback onDeleteTheme;
  final VoidCallback onRestoreBuiltins;

  @override
  State<_PalettePresetControl> createState() => _PalettePresetControlState();
}

class _PalettePresetControlState extends State<_PalettePresetControl> {
  bool _hoverPill = false;
  final GlobalKey _pillKey = GlobalKey();

  void _openMenu() {
    if (widget.entries.isEmpty && !widget.canManage) return;
    final box =
        (_pillKey.currentContext?.findRenderObject() ??
                context.findRenderObject())!
            as RenderBox;
    final isZh = widget.isZh;
    unawaited(
      showIdeMenu(
        context,
        anchor: box.localToGlobal(Offset.zero) & box.size,
        entries: ideMenuGroups([
          if (widget.entries.isNotEmpty)
            [
              for (final entry in widget.entries)
                IdeMenuAction(
                  entry.isCustom
                      ? '${entry.label} (${isZh ? '自定义' : 'Custom'})'
                      : entry.label,
                  checked: entry.id == widget.selectedId,
                  onSelected: () => widget.onSelected(entry.id),
                ),
            ],
          if (widget.canManage)
            [
              IdeMenuAction(
                isZh ? '新建主题…' : 'New Theme…',
                onSelected: widget.onAddTheme,
              ),
              IdeMenuAction(
                isZh ? '另存当前配色为新主题…' : 'Save Current Colors as New Theme…',
                onSelected: widget.onSaveAsNewTheme,
              ),
              if (widget.isCustomTheme)
                IdeMenuAction(
                  isZh ? '重命名当前主题…' : 'Rename Current Theme…',
                  onSelected: widget.onRenameTheme,
                ),
              if (widget.hasCustomColors)
                IdeMenuAction(
                  isZh ? '重置当前主题配色' : 'Reset Theme Colors',
                  onSelected: widget.onResetColors,
                ),
              if (widget.canDelete)
                IdeMenuAction(
                  isZh ? '删除当前主题…' : 'Delete Current Theme…',
                  onSelected: widget.onDeleteTheme,
                ),
              if (widget.hasDeletedBuiltins)
                IdeMenuAction(
                  isZh ? '恢复已删除的内置主题' : 'Restore Deleted Built-in Themes',
                  onSelected: widget.onRestoreBuiltins,
                ),
            ],
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pillFill = AppColors.text.withValues(alpha: 0.06);
    final pillHoverFill = AppColors.text.withValues(alpha: 0.10);
    final isZh = widget.isZh;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!widget.isActive) ...[
          _PaletteActionChip(
            label: isZh ? '应用' : 'Apply',
            onTap: widget.onApplyCurrent,
          ),
          const SizedBox(width: 6),
        ],
        if (widget.hasCustomColors) ...[
          _PaletteIconButton(
            icon: Icons.undo_rounded,
            tooltip: isZh ? '重置当前主题配色' : 'Reset theme colors',
            onTap: widget.onResetColors,
          ),
          const SizedBox(width: 2),
        ],
        if (widget.canManage) ...[
          _PaletteIconButton(
            icon: Icons.add_rounded,
            tooltip: isZh ? '新建主题 / 另存配色' : 'New theme',
            onTap: widget.onAddTheme,
          ),
          if (widget.isCustomTheme) ...[
            const SizedBox(width: 2),
            _PaletteIconButton(
              icon: Icons.edit_outlined,
              tooltip: isZh ? '重命名主题' : 'Rename theme',
              onTap: widget.onRenameTheme,
            ),
          ],
          if (widget.canDelete) ...[
            const SizedBox(width: 2),
            _PaletteIconButton(
              icon: Icons.delete_outline_rounded,
              tooltip: isZh ? '删除当前主题' : 'Delete theme',
              onTap: widget.onDeleteTheme,
            ),
          ],
          const SizedBox(width: 6),
        ],
        MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hoverPill = true),
          onExit: (_) => setState(() => _hoverPill = false),
          child: GestureDetector(
            key: _pillKey,
            behavior: HitTestBehavior.opaque,
            onTap: _openMenu,
            child: Container(
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: _hoverPill ? pillHoverFill : pillFill,
                borderRadius: BorderRadius.circular(999),
                border: widget.isActive
                    ? Border.all(
                        color: AppColors.accent.withValues(alpha: 0.35),
                      )
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.isActive) ...[
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: AppColors.accent,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 165),
                    child: RichText(
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      text: TextSpan(
                        text: widget.hasCustomColors
                            ? '${widget.label} *'
                            : widget.label,
                        style: TextStyle(
                          color: AppColors.text,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 5),
                  Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 15,
                    color: AppColors.textMuted,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PaletteActionChip extends StatefulWidget {
  const _PaletteActionChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  State<_PaletteActionChip> createState() => _PaletteActionChipState();
}

class _PaletteActionChipState extends State<_PaletteActionChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          height: 26,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.accent.withValues(alpha: _hover ? 0.18 : 0.11),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: AppColors.accent,
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class _PaletteIconButton extends StatefulWidget {
  const _PaletteIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_PaletteIconButton> createState() => _PaletteIconButtonState();
}

class _PaletteIconButtonState extends State<_PaletteIconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final hoverFill = AppColors.text.withValues(alpha: 0.08);
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 350),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hover ? hoverFill : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              widget.icon,
              size: 15.5,
              color: _hover ? AppColors.text : AppColors.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}

class _PaletteColorPill extends StatefulWidget {
  const _PaletteColorPill({
    required this.isZh,
    required this.dark,
    required this.slot,
    required this.label,
    required this.color,
    required this.defaultColor,
    required this.customized,
    required this.onPreview,
    required this.onChanged,
  });

  final bool isZh;
  final bool dark;
  final String slot;
  final String label;
  final Color color;
  final Color defaultColor;
  final bool customized;
  final ValueChanged<Color?> onPreview;
  final ValueChanged<Color?> onChanged;

  @override
  State<_PaletteColorPill> createState() => _PaletteColorPillState();
}

class _PaletteColorPillState extends State<_PaletteColorPill> {
  bool _hover = false;

  Future<void> _editColor() async {
    final beforeColor = widget.customized ? widget.color : null;
    final result = await showDialog<_ColorPickerOutcome>(
      context: context,
      barrierColor: const Color(0x4D000000),
      builder: (context) => _ColorPickerDialog(
        isZh: widget.isZh,
        dark: widget.dark,
        slot: widget.slot,
        label: widget.label,
        initialColor: widget.color,
        defaultColor: widget.defaultColor,
        onPreview: (picked) {
          final normalized =
              picked.toARGB32() == widget.defaultColor.toARGB32()
              ? null
              : picked;
          widget.onPreview(normalized);
        },
      ),
    );
    if (result == null) {
      // Cancelled -> revert live preview back to the state before opening.
      widget.onPreview(beforeColor);
      return;
    }
    if (result.reset) {
      widget.onChanged(null);
      return;
    }
    final chosen = result.color;
    if (chosen != null) {
      widget.onChanged(
        chosen.toARGB32() == widget.defaultColor.toARGB32() ? null : chosen,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final hex = ThemePaletteOverrides.toHex(widget.color).substring(1);
    final pillFill = AppColors.text.withValues(alpha: 0.05);
    final pillHoverFill = AppColors.text.withValues(alpha: 0.09);
    final pillBorder = widget.customized
        ? AppColors.accent.withValues(alpha: 0.45)
        : AppColors.text.withValues(alpha: 0.10);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _editColor,
        child: Container(
          height: 28,
          padding: const EdgeInsets.only(left: 7, right: 12),
          decoration: BoxDecoration(
            color: _hover ? pillHoverFill : pillFill,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: pillBorder),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: widget.color,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: AppColors.text.withValues(alpha: 0.16),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '# ',
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12.5,
                      ),
                    ),
                    TextSpan(
                      text: hex,
                      style: TextStyle(
                        color: AppColors.text,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ColorPickerOutcome {
  const _ColorPickerOutcome({this.color, this.reset = false});
  final Color? color;
  final bool reset;
}

class _ColorPickerDialog extends StatefulWidget {
  const _ColorPickerDialog({
    required this.isZh,
    required this.dark,
    required this.slot,
    required this.label,
    required this.initialColor,
    required this.defaultColor,
    required this.onPreview,
  });

  final bool isZh;
  final bool dark;
  final String slot;
  final String label;
  final Color initialColor;
  final Color defaultColor;
  final ValueChanged<Color> onPreview;

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  late HSVColor _hsv = HSVColor.fromColor(widget.initialColor);
  late final TextEditingController _hexController = TextEditingController(
    text: ThemePaletteOverrides.toHex(widget.initialColor).substring(1),
  );
  bool _updatingText = false;

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  List<Color> _swatches() {
    return switch ((widget.dark, widget.slot)) {
      (
        false,
        ThemePaletteOverrides.slotBackground ||
            ThemePaletteOverrides.slotSidebar ||
            ThemePaletteOverrides.slotCard,
      ) =>
        const [
          Color(0xFFFFFFFF),
          Color(0xFFFAF9F5),
          Color(0xFFF6F5F0),
          Color(0xFFEFEEEA),
          Color(0xFFEBE8E0),
          Color(0xFFFDFBF7),
          Color(0xFFF7F8FA),
          Color(0xFFEEF1F5),
          Color(0xFFF4F7F4),
          Color(0xFFE8EFE9),
          Color(0xFFFBF7F2),
          Color(0xFFF3ECE4),
        ],
      (
        true,
        ThemePaletteOverrides.slotBackground ||
            ThemePaletteOverrides.slotSidebar ||
            ThemePaletteOverrides.slotCard,
      ) =>
        const [
          Color(0xFF121212),
          Color(0xFF161615),
          Color(0xFF1D1C1A),
          Color(0xFF252421),
          Color(0xFF2D2C28),
          Color(0xFF0F1115),
          Color(0xFF161920),
          Color(0xFF1E222B),
          Color(0xFF141816),
          Color(0xFF1B211E),
          Color(0xFF1C191F),
          Color(0xFF26212B),
        ],
      (_, ThemePaletteOverrides.slotForeground) => const [
        Color(0xFF181817),
        Color(0xFF2B2A28),
        Color(0xFF334155),
        Color(0xFF3F3D39),
        Color(0xFFE6E3DC),
        Color(0xFFF3F2EE),
        Color(0xFFE2E8F0),
        Color(0xFFFFFFFF),
      ],
      _ => const [
        Color(0xFF9E2825),
        Color(0xFFC2410C),
        Color(0xFFD97757),
        Color(0xFFB45309),
        Color(0xFF15803D),
        Color(0xFF0F766E),
        Color(0xFF2B6CB0),
        Color(0xFF2563EB),
        Color(0xFF4F46E5),
        Color(0xFF7C3AED),
        Color(0xFFBE185D),
        Color(0xFFE599F7),
      ],
    };
  }

  void _setHsv(HSVColor next, {bool syncHex = true}) {
    final color = next.toColor();
    setState(() => _hsv = next);
    if (syncHex) {
      _updatingText = true;
      _hexController.text = ThemePaletteOverrides.toHex(color).substring(1);
      _updatingText = false;
    }
    widget.onPreview(color);
  }

  void _setColor(Color color) => _setHsv(HSVColor.fromColor(color));

  void _onHexChanged(String text) {
    if (_updatingText) return;
    final parsed = ThemePaletteOverrides.parseHex(text);
    if (parsed != null) {
      _setHsv(HSVColor.fromColor(parsed), syncHex: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isZh = widget.isZh;
    final currentColor = _hsv.toColor();
    final swatches = _swatches();

    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: AppColors.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.label,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: currentColor,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: AppColors.text.withValues(alpha: 0.18),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // 2D Saturation / Value canvas
              SizedBox(
                height: 150,
                width: double.infinity,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    void pickAt(Offset local) {
                      final s = (local.dx / constraints.maxWidth).clamp(
                        0.0,
                        1.0,
                      );
                      final v = (1.0 - local.dy / constraints.maxHeight).clamp(
                        0.0,
                        1.0,
                      );
                      _setHsv(_hsv.withSaturation(s).withValue(v));
                    }

                    return GestureDetector(
                      onPanDown: (d) => pickAt(d.localPosition),
                      onPanUpdate: (d) => pickAt(d.localPosition),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: CustomPaint(
                          painter: _SaturationValuePainter(hsv: _hsv),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 10),
              // Hue slider bar
              SizedBox(
                height: 16,
                width: double.infinity,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    void pickHue(Offset local) {
                      final h = ((local.dx / constraints.maxWidth).clamp(
                        0.0,
                        1.0,
                      )) *
                          360.0;
                      _setHsv(_hsv.withHue(h < 360 ? h : 0));
                    }

                    return GestureDetector(
                      onPanDown: (d) => pickHue(d.localPosition),
                      onPanUpdate: (d) => pickHue(d.localPosition),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: CustomPaint(painter: _HueBarPainter(hue: _hsv.hue)),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              // Quick preset swatches
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: [
                  for (final swatch in swatches)
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: () => _setColor(swatch),
                        child: Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            color: swatch,
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(
                              color:
                                  swatch.toARGB32() == currentColor.toARGB32()
                                  ? AppColors.accent
                                  : AppColors.text.withValues(alpha: 0.16),
                              width:
                                  swatch.toARGB32() == currentColor.toARGB32()
                                  ? 1.8
                                  : 1.0,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              // Hex input
              TextField(
                controller: _hexController,
                style: TextStyle(
                  color: AppColors.text,
                  fontFamily: AppFonts.mono,
                  fontFamilyFallback: AppFonts.monoFallbacks,
                  fontSize: 13,
                ),
                decoration: _dialogInputDecoration(prefixText: '# '),
                onChanged: _onHexChanged,
                onSubmitted: (value) {
                  final parsed = ThemePaletteOverrides.parseHex(value);
                  Navigator.pop(
                    context,
                    _ColorPickerOutcome(color: parsed ?? currentColor),
                  );
                },
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  _DialogTextButton(
                    label: isZh ? '恢复默认' : 'Reset',
                    onTap: () => Navigator.pop(
                      context,
                      const _ColorPickerOutcome(reset: true),
                    ),
                  ),
                  const Spacer(),
                  _DialogTextButton(
                    label: isZh ? '取消' : 'Cancel',
                    onTap: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 6),
                  _DialogPrimaryButton(
                    label: isZh ? '保存' : 'Save',
                    onTap: () {
                      final parsed = ThemePaletteOverrides.parseHex(
                        _hexController.text,
                      );
                      Navigator.pop(
                        context,
                        _ColorPickerOutcome(color: parsed ?? currentColor),
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SaturationValuePainter extends CustomPainter {
  const _SaturationValuePainter({required this.hsv});

  final HSVColor hsv;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final pureHue = HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor();
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [const Color(0xFFFFFFFF), pureHue],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Color(0xFF000000)],
        ).createShader(rect),
    );

    final knob = Offset(
      hsv.saturation * size.width,
      (1.0 - hsv.value) * size.height,
    );
    canvas.drawCircle(
      knob,
      6.5,
      Paint()
        ..color = const Color(0x99000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
    canvas.drawCircle(
      knob,
      6.5,
      Paint()
        ..color = const Color(0xFFFFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );
  }

  @override
  bool shouldRepaint(covariant _SaturationValuePainter oldDelegate) =>
      oldDelegate.hsv != hsv;
}

class _HueBarPainter extends CustomPainter {
  const _HueBarPainter({required this.hue});

  final double hue;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          colors: [
            Color(0xFFFF0000),
            Color(0xFFFFFF00),
            Color(0xFF00FF00),
            Color(0xFF00FFFF),
            Color(0xFF0000FF),
            Color(0xFFFF00FF),
            Color(0xFFFF0000),
          ],
        ).createShader(rect),
    );
    final x = ((hue / 360.0).clamp(0.0, 1.0)) * size.width;
    final center = Offset(x.clamp(6.0, size.width - 6.0), size.height / 2);
    canvas.drawCircle(
      center,
      6.5,
      Paint()
        ..color = const Color(0x88000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4,
    );
    canvas.drawCircle(
      center,
      6.5,
      Paint()
        ..color = const Color(0xFFFFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8,
    );
  }

  @override
  bool shouldRepaint(covariant _HueBarPainter oldDelegate) =>
      oldDelegate.hue != hue;
}
