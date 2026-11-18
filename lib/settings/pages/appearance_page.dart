import 'dart:async';

import 'package:bao_editor/monaco/flutter/editor_document_model.dart';
import 'package:bao_editor/monaco/flutter/editor_surface_controller.dart';
import 'package:bao_editor/monaco/vs/platform/theme/common/theme.dart';
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

/// Persistent Light Theme / Dark Theme palette customizer & theme manager:
/// - Modifies any built-in or custom theme's colors directly in-place
///   (`workbench.themeOverrides` in `settings.json`), with live preview and
///   per-slot or whole-theme reset.
/// - Creates new themes (`+`), renames custom themes, deletes custom or
///   built-in themes, and restores deleted built-in themes.
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
  String? _inspectedId;

  String _resolveTargetId() {
    final entries = widget.entries;
    final activeId = widget.themes.colorThemeId;
    if (entries.any((e) => e.id == activeId)) {
      _inspectedId = activeId;
      return activeId;
    }
    if (_inspectedId != null && entries.any((e) => e.id == _inspectedId)) {
      return _inspectedId!;
    }
    final fallback = widget.dark
        ? ThemeSettingDefaults.colorThemeDark
        : 'Antigravity Light';
    if (entries.any((e) => e.id == fallback)) {
      return _inspectedId = fallback;
    }
    if (entries.isNotEmpty) {
      return _inspectedId = entries.first.id;
    }
    return widget.dark
        ? ThemeSettingDefaults.colorThemeDark
        : ThemeSettingDefaults.colorThemeLight;
  }

  String _labelFor(String id) {
    for (final entry in widget.entries) {
      if (entry.id == id) return entry.label;
    }
    return id;
  }

  Future<void> _promptCreateTheme(
    BuildContext context, {
    required String baseId,
    required String baseLabel,
    required bool isZh,
  }) async {
    final suggested = isZh ? '$baseLabel · 自定义' : '$baseLabel Custom';
    final name = await _showThemeNameDialog(
      context,
      title: isZh
          ? (widget.dark ? '新建深色主题' : '新建浅色主题')
          : (widget.dark ? 'New Dark Theme' : 'New Light Theme'),
      subtitle: isZh
          ? '将基于「$baseLabel」当前的配色创建独立主题并自动应用'
          : 'Creates a standalone theme based on "$baseLabel" and applies it',
      initialValue: suggested,
      confirmLabel: isZh ? '创建主题' : 'Create',
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    final createdId = await ThemePaletteOverrides.createCustomTheme(
      label: name,
      dark: widget.dark,
      baseThemeId: baseId,
      copyBaseOverrides: true,
    );
    if (mounted) {
      setState(() => _inspectedId = createdId);
    }
  }

  Future<void> _promptRenameTheme(
    BuildContext context, {
    required String targetId,
    required String currentLabel,
    required bool isZh,
  }) async {
    final name = await _showThemeNameDialog(
      context,
      title: isZh ? '重命名主题' : 'Rename Theme',
      subtitle: isZh ? '输入新的主题名称' : 'Enter a new name for this theme',
      initialValue: currentLabel,
      confirmLabel: isZh ? '保存' : 'Save',
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    final nextId = await ThemePaletteOverrides.renameCustomTheme(
      targetId,
      name,
    );
    if (mounted) {
      setState(() => _inspectedId = nextId);
    }
  }

  Future<void> _confirmDeleteTheme(
    BuildContext context, {
    required String targetId,
    required String label,
    required bool isCustom,
    required bool isZh,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: const Color(0x66000000),
      builder: (ctx) => Dialog(
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
                  isZh ? '删除主题「$label」？' : 'Delete "$label"?',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  isCustom
                      ? (isZh
                            ? '该自定义主题及其配色文件将被永久移除。'
                            : 'This custom theme and its palette file will be permanently deleted.')
                      : (isZh
                            ? '该内置主题将从主题列表中移除（后续可随时在菜单中恢复）。'
                            : 'This built-in theme will be removed from theme lists (you can restore it anytime from the menu).'),
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
                    _DialogActionButton(
                      label: isZh ? '取消' : 'Cancel',
                      onTap: () => Navigator.pop(ctx, false),
                    ),
                    const SizedBox(width: 8),
                    _DialogActionButton(
                      label: isZh ? '删除' : 'Delete',
                      destructive: true,
                      primary: true,
                      onTap: () => Navigator.pop(ctx, true),
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
    await ThemePaletteOverrides.deleteTheme(targetId, dark: widget.dark);
    if (mounted) {
      setState(() => _inspectedId = null);
    }
  }

  Future<void> _updateSlot(
    String targetId,
    String slot,
    Color? color,
  ) async {
    if (widget.themes.colorThemeId != targetId) {
      widget.onSelectPreset(targetId);
    }
    await ThemePaletteOverrides.setSlotColor(targetId, slot, color);
  }

  @override
  Widget build(BuildContext context) {
    final isZh = Localizations.maybeLocaleOf(context)?.languageCode == 'zh';
    final targetId = _resolveTargetId();
    final targetLabel = _labelFor(targetId);
    final isCustom = ThemePaletteOverrides.isCustomTheme(targetId);
    final hasOverrides = ThemePaletteOverrides.hasCustomFor(targetId);
    final canDelete = ThemePaletteOverrides.canDeleteTheme(
      targetId,
      sameSchemeCount: widget.entries.length,
    );
    final deletedBuiltins = ThemePaletteOverrides.deletedThemes;

    final baseSlots = WorkbenchThemeService.instance.baseSlotColors(
      targetId,
      dark: widget.dark,
    );
    Color effective(String slot, Color fallback) =>
        ThemePaletteOverrides.slotColor(targetId, slot) ??
        baseSlots[slot] ??
        fallback;
    Color baseOf(String slot, Color fallback) => baseSlots[slot] ?? fallback;

    final bgDefault = baseOf(
      ThemePaletteOverrides.slotBackground,
      widget.dark
          ? ThemePaletteOverrides.defaultDarkBackground
          : ThemePaletteOverrides.defaultLightBackground,
    );
    final sbDefault = baseOf(
      ThemePaletteOverrides.slotSidebar,
      widget.dark
          ? ThemePaletteOverrides.defaultDarkSidebar
          : ThemePaletteOverrides.defaultLightSidebar,
    );
    final cardDefault = baseOf(
      ThemePaletteOverrides.slotCard,
      widget.dark
          ? ThemePaletteOverrides.defaultDarkCard
          : ThemePaletteOverrides.defaultLightCard,
    );
    final fgDefault = baseOf(
      ThemePaletteOverrides.slotForeground,
      widget.dark
          ? ThemePaletteOverrides.defaultDarkForeground
          : ThemePaletteOverrides.defaultLightForeground,
    );
    final accentDefault = baseOf(
      ThemePaletteOverrides.slotAccent,
      widget.dark
          ? ThemePaletteOverrides.defaultDarkAccent
          : ThemePaletteOverrides.defaultLightAccent,
    );
    final codeDefault = baseOf(
      ThemePaletteOverrides.slotInlineCode,
      widget.dark
          ? ThemePaletteOverrides.defaultDarkInlineCode
          : ThemePaletteOverrides.defaultLightInlineCode,
    );

    final bg = effective(ThemePaletteOverrides.slotBackground, bgDefault);
    final sb = effective(ThemePaletteOverrides.slotSidebar, sbDefault);
    final card = effective(ThemePaletteOverrides.slotCard, cardDefault);
    final fg = effective(ThemePaletteOverrides.slotForeground, fgDefault);
    final accent = effective(ThemePaletteOverrides.slotAccent, accentDefault);
    final code = effective(ThemePaletteOverrides.slotInlineCode, codeDefault);

    final slots =
        <({String slot, String label, String desc, Color color, Color def})>[
          (
            slot: ThemePaletteOverrides.slotBackground,
            label: isZh ? '主背景 (Background)' : 'Background',
            desc: isZh ? '对话主画布与编辑器工作区底色' : 'Conversation & editor canvas',
            color: bg,
            def: bgDefault,
          ),
          (
            slot: ThemePaletteOverrides.slotSidebar,
            label: isZh ? '侧边栏 (Sidebar)' : 'Sidebar',
            desc: isZh ? '左侧会话树、标题栏与状态栏底色' : 'Sidebar, title bar & status bar',
            color: sb,
            def: sbDefault,
          ),
          (
            slot: ThemePaletteOverrides.slotCard,
            label: isZh ? '卡片与气泡 (Surface)' : 'Surface & Cards',
            desc: isZh
                ? '输入框、用户气泡、菜单与侧边栏选中项底色'
                : 'Composer, user bubble, menus & active row',
            color: card,
            def: cardDefault,
          ),
          (
            slot: ThemePaletteOverrides.slotForeground,
            label: isZh ? '主文字 (Foreground)' : 'Foreground',
            desc: isZh ? '正文与界面主文字颜色（次级文字自动推算）' : 'Primary text & icons',
            color: fg,
            def: fgDefault,
          ),
          (
            slot: ThemePaletteOverrides.slotAccent,
            label: isZh ? '强调色 (Accent)' : 'Accent',
            desc: isZh ? '主按钮、链接、焦点边框与高亮指示' : 'Buttons, links & focus highlights',
            color: accent,
            def: accentDefault,
          ),
          (
            slot: ThemePaletteOverrides.slotInlineCode,
            label: isZh ? '行内代码 (Inline Code)' : 'Inline Code',
            desc: isZh ? 'Markdown 行内代码胶囊的文字颜色' : 'Markdown inline code text color',
            color: code,
            def: codeDefault,
          ),
        ];

    return SettingsGroup(
      title: isZh
          ? (widget.dark ? '深色主题与配色管理' : '浅色主题与配色管理')
          : (widget.dark ? 'Dark Theme' : 'Light Theme'),
      children: [
        SettingsRow(
          label: isZh ? '当前预设 (Preset)' : 'Preset',
          description: isZh
              ? '可直接修改下方任意颜色实时生效并自动保存，也可新建、重命名或删除主题'
              : 'Edit colors below in-place (auto-saved), or add, rename, and delete themes',
          trailing: _PalettePresetControl(
            targetId: targetId,
            label: targetLabel,
            isCustom: isCustom,
            hasOverrides: hasOverrides,
            canDelete: canDelete,
            hasDeletedBuiltins: deletedBuiltins.isNotEmpty,
            isZh: isZh,
            entries: [
              for (final entry in widget.entries)
                (
                  id: entry.id,
                  label: entry.label,
                  modified: ThemePaletteOverrides.hasCustomFor(entry.id),
                ),
            ],
            onReset: () => unawaited(ThemePaletteOverrides.resetTheme(targetId)),
            onSelected: (id) {
              setState(() => _inspectedId = id);
              widget.onSelectPreset(id);
            },
            onCreateNew: () => unawaited(
              _promptCreateTheme(
                context,
                baseId: targetId,
                baseLabel: targetLabel,
                isZh: isZh,
              ),
            ),
            onRename: isCustom
                ? () => unawaited(
                    _promptRenameTheme(
                      context,
                      targetId: targetId,
                      currentLabel: targetLabel,
                      isZh: isZh,
                    ),
                  )
                : null,
            onDelete: canDelete
                ? () => unawaited(
                    _confirmDeleteTheme(
                      context,
                      targetId: targetId,
                      label: targetLabel,
                      isCustom: isCustom,
                      isZh: isZh,
                    ),
                  )
                : null,
            onRestoreDeleted: deletedBuiltins.isNotEmpty
                ? () => unawaited(ThemePaletteOverrides.restoreDeletedThemes())
                : null,
          ),
        ),
        for (final item in slots)
          SettingsRow(
            label: item.label,
            description: item.desc,
            trailing: _PaletteColorPill(
              label: item.label,
              color: item.color,
              defaultColor: item.def,
              isModified:
                  ThemePaletteOverrides.slotColor(targetId, item.slot) != null,
              isZh: isZh,
              onChanged: (color) =>
                  unawaited(_updateSlot(targetId, item.slot, color)),
            ),
          ),
      ],
    );
  }
}

Future<String?> _showThemeNameDialog(
  BuildContext context, {
  required String title,
  required String subtitle,
  required String initialValue,
  required String confirmLabel,
}) async {
  final isZh = Localizations.maybeLocaleOf(context)?.languageCode == 'zh';
  final controller = TextEditingController(text: initialValue);
  controller.selection = TextSelection(
    baseOffset: 0,
    extentOffset: initialValue.length,
  );
  final result = await showDialog<String>(
    context: context,
    barrierColor: const Color(0x66000000),
    builder: (ctx) => Dialog(
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
                title,
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                style: TextStyle(color: AppColors.text, fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 9,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: AppColors.borderStrong),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: AppColors.accent),
                  ),
                ),
                onSubmitted: (value) => Navigator.pop(ctx, value),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _DialogActionButton(
                    label: isZh ? '取消' : 'Cancel',
                    onTap: () => Navigator.pop(ctx),
                  ),
                  const SizedBox(width: 8),
                  _DialogActionButton(
                    label: confirmLabel,
                    primary: true,
                    onTap: () => Navigator.pop(ctx, controller.text),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
  controller.dispose();
  return result;
}

class _DialogActionButton extends StatefulWidget {
  const _DialogActionButton({
    required this.label,
    required this.onTap,
    this.primary = false,
    this.destructive = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool primary;
  final bool destructive;

  @override
  State<_DialogActionButton> createState() => _DialogActionButtonState();
}

class _DialogActionButtonState extends State<_DialogActionButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final bg = widget.primary
        ? (widget.destructive
              ? const Color(0xFFD9383A)
              : AppColors.accent)
        : (_hover
              ? AppColors.text.withValues(alpha: 0.08)
              : Colors.transparent);
    final fg = widget.primary
        ? (widget.destructive
              ? Colors.white
              : themeColors['button.foreground'])
        : AppColors.textMuted;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: fg,
              fontSize: 12,
              fontWeight: widget.primary ? FontWeight.w500 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}

class _PalettePresetControl extends StatefulWidget {
  const _PalettePresetControl({
    required this.targetId,
    required this.label,
    required this.isCustom,
    required this.hasOverrides,
    required this.canDelete,
    required this.hasDeletedBuiltins,
    required this.isZh,
    required this.entries,
    required this.onReset,
    required this.onSelected,
    required this.onCreateNew,
    this.onRename,
    this.onDelete,
    this.onRestoreDeleted,
  });

  final String targetId;
  final String label;
  final bool isCustom;
  final bool hasOverrides;
  final bool canDelete;
  final bool hasDeletedBuiltins;
  final bool isZh;
  final List<({String id, String label, bool modified})> entries;
  final VoidCallback onReset;
  final ValueChanged<String> onSelected;
  final VoidCallback onCreateNew;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;
  final VoidCallback? onRestoreDeleted;

  @override
  State<_PalettePresetControl> createState() => _PalettePresetControlState();
}

class _PalettePresetControlState extends State<_PalettePresetControl> {
  final GlobalKey _pillKey = GlobalKey();
  final GlobalKey _moreKey = GlobalKey();
  bool _hoverReset = false;
  bool _hoverPill = false;
  bool _hoverAdd = false;
  bool _hoverMore = false;

  void _openPresetMenu() {
    final ctx = _pillKey.currentContext ?? context;
    final box = ctx.findRenderObject()! as RenderBox;
    unawaited(
      showIdeMenu(
        context,
        anchor: box.localToGlobal(Offset.zero) & box.size,
        entries: ideMenuGroups([
          [
            for (final entry in widget.entries)
              IdeMenuAction(
                entry.modified ? '${entry.label} •' : entry.label,
                checked: entry.id == widget.targetId,
                onSelected: () => widget.onSelected(entry.id),
              ),
          ],
          [
            IdeMenuAction(
              widget.isZh ? '+ 新建主题…' : '+ New Theme…',
              onSelected: widget.onCreateNew,
            ),
          ],
        ]),
      ),
    );
  }

  void _openManageMenu() {
    final ctx = _moreKey.currentContext ?? context;
    final box = ctx.findRenderObject()! as RenderBox;
    final z = widget.isZh;
    unawaited(
      showIdeMenu(
        context,
        anchor: box.localToGlobal(Offset.zero) & box.size,
        entries: ideMenuGroups([
          [
            IdeMenuAction(
              z ? '基于当前配色新建主题…' : 'Save Palette as New Theme…',
              onSelected: widget.onCreateNew,
            ),
            if (widget.onRename != null)
              IdeMenuAction(
                z ? '重命名当前主题…' : 'Rename Theme…',
                onSelected: widget.onRename!,
              ),
            if (widget.hasOverrides)
              IdeMenuAction(
                z ? '恢复当前主题初始配色' : 'Reset Modified Colors',
                onSelected: widget.onReset,
              ),
          ],
          [
            if (widget.onDelete != null)
              IdeMenuAction(
                z ? '删除主题「${widget.label}」…' : 'Delete "${widget.label}"…',
                onSelected: widget.onDelete!,
              ),
            if (widget.onRestoreDeleted != null)
              IdeMenuAction(
                z ? '恢复已删除的内置主题' : 'Restore Deleted Built-in Themes',
                onSelected: widget.onRestoreDeleted!,
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
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.hasOverrides) ...[
          Tooltip(
            message: widget.isZh ? '恢复当前主题默认配色' : 'Reset theme colors',
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              onEnter: (_) => setState(() => _hoverReset = true),
              onExit: (_) => setState(() => _hoverReset = false),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onReset,
                child: Container(
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _hoverReset ? pillFill : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(
                    Icons.undo_rounded,
                    size: 15,
                    color: _hoverReset ? AppColors.text : AppColors.textMuted,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
        ],
        MouseRegion(
          key: _pillKey,
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hoverPill = true),
          onExit: (_) => setState(() => _hoverPill = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _openPresetMenu,
            child: Container(
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: _hoverPill ? pillHoverFill : pillFill,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.hasOverrides) ...[
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
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.text,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
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
        const SizedBox(width: 4),
        Tooltip(
          message: widget.isZh ? '新建主题' : 'Add new theme',
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hoverAdd = true),
            onExit: (_) => setState(() => _hoverAdd = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onCreateNew,
              child: Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _hoverAdd ? pillHoverFill : pillFill,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Icon(
                  Icons.add_rounded,
                  size: 16,
                  color: _hoverAdd ? AppColors.text : AppColors.textMuted,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        Tooltip(
          message: widget.isZh ? '管理主题（重命名 / 删除 / 恢复）' : 'Manage theme',
          child: MouseRegion(
            key: _moreKey,
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hoverMore = true),
            onExit: (_) => setState(() => _hoverMore = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _openManageMenu,
              child: Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _hoverMore ? pillHoverFill : Colors.transparent,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Icon(
                  Icons.more_horiz_rounded,
                  size: 16,
                  color: _hoverMore ? AppColors.text : AppColors.textMuted,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PaletteColorPill extends StatefulWidget {
  const _PaletteColorPill({
    required this.label,
    required this.color,
    required this.defaultColor,
    required this.isModified,
    required this.isZh,
    required this.onChanged,
  });

  final String label;
  final Color color;
  final Color defaultColor;
  final bool isModified;
  final bool isZh;
  final ValueChanged<Color?> onChanged;

  @override
  State<_PaletteColorPill> createState() => _PaletteColorPillState();
}

class _PaletteColorPillState extends State<_PaletteColorPill> {
  bool _hover = false;

  void _applyNormalized(Color picked) {
    widget.onChanged(
      picked.toARGB32() == widget.defaultColor.toARGB32() ? null : picked,
    );
  }

  Future<void> _editColor() async {
    final beforeColor = widget.color;
    final wasModified = widget.isModified;
    final accepted = await showDialog<bool>(
      context: context,
      barrierColor: const Color(0x4D000000),
      builder: (ctx) => _ColorPickerDialog(
        label: widget.label,
        initialColor: widget.color,
        defaultColor: widget.defaultColor,
        isZh: widget.isZh,
        onPreview: _applyNormalized,
      ),
    );
    if (accepted != true) {
      // Cancelled or dismissed outside: revert live preview to previous state.
      widget.onChanged(wasModified ? beforeColor : null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hex = ThemePaletteOverrides.toHex(widget.color).substring(1);
    final pillFill = AppColors.text.withValues(alpha: 0.05);
    final pillHoverFill = AppColors.text.withValues(alpha: 0.09);
    final pillBorder = widget.isModified
        ? AppColors.accent.withValues(alpha: 0.40)
        : AppColors.text.withValues(alpha: 0.10);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.isModified) ...[
          Tooltip(
            message: widget.isZh ? '恢复默认颜色' : 'Reset to default',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => widget.onChanged(null),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Icon(
                  Icons.replay_rounded,
                  size: 13.5,
                  color: AppColors.textMuted,
                ),
              ),
            ),
          ),
          const SizedBox(width: 2),
        ],
        MouseRegion(
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
        ),
      ],
    );
  }
}

class _ColorPickerDialog extends StatefulWidget {
  const _ColorPickerDialog({
    required this.label,
    required this.initialColor,
    required this.defaultColor,
    required this.isZh,
    required this.onPreview,
  });

  final String label;
  final Color initialColor;
  final Color defaultColor;
  final bool isZh;
  final ValueChanged<Color> onPreview;

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  static const _swatches = <Color>[
    Color(0xFFFAF9F5),
    Color(0xFFF6F3EB),
    Color(0xFFEFEEEA),
    Color(0xFFFFFFFF),
    Color(0xFFF3F4F6),
    Color(0xFFFDF6E3),
    Color(0xFF1F1E1D),
    Color(0xFF18181B),
    Color(0xFF141413),
    Color(0xFF252421),
    Color(0xFFE6E3DC),
    Color(0xFFCF795A),
    Color(0xFF2860E8),
    Color(0xFF0D9488),
    Color(0xFF7C3AED),
    Color(0xFF9E2825),
  ];

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

  void _setHsv(HSVColor next) {
    final color = next.toColor();
    setState(() => _hsv = next);
    _updatingText = true;
    final hex = ThemePaletteOverrides.toHex(color).substring(1);
    if (_hexController.text.toUpperCase() != hex) {
      _hexController.value = TextEditingValue(
        text: hex,
        selection: TextSelection.collapsed(offset: hex.length),
      );
    }
    _updatingText = false;
    widget.onPreview(color);
  }

  void _setColor(Color color) => _setHsv(HSVColor.fromColor(color));

  void _onHexEdited(String raw) {
    if (_updatingText) return;
    final parsed = ThemePaletteOverrides.parseHex(raw);
    if (parsed != null) {
      setState(() => _hsv = HSVColor.fromColor(parsed));
      widget.onPreview(parsed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentColor = _hsv.toColor();
    final z = widget.isZh;
    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: AppColors.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 316),
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
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13.5,
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
              // 2D Saturation / Value canvas.
              SizedBox(
                height: 148,
                width: double.infinity,
                child: _SatValBox(
                  hsv: _hsv,
                  onChanged: _setHsv,
                ),
              ),
              const SizedBox(height: 10),
              // Hue slider bar.
              SizedBox(
                height: 16,
                width: double.infinity,
                child: _HueStrip(
                  hue: _hsv.hue,
                  onChanged: (hue) => _setHsv(_hsv.withHue(hue)),
                ),
              ),
              const SizedBox(height: 12),
              // Quick preset swatches.
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final swatch in _swatches)
                    GestureDetector(
                      onTap: () => _setColor(swatch),
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
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
              TextField(
                controller: _hexController,
                onChanged: _onHexEdited,
                style: TextStyle(
                  color: AppColors.text,
                  fontFamily: AppFonts.mono,
                  fontFamilyFallback: AppFonts.monoFallbacks,
                  fontSize: 13,
                ),
                decoration: InputDecoration(
                  prefixText: '# ',
                  prefixStyle: TextStyle(
                    color: AppColors.textMuted,
                    fontFamily: AppFonts.mono,
                    fontSize: 13,
                  ),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: AppColors.borderStrong),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: AppColors.accent),
                  ),
                ),
                onSubmitted: (value) {
                  final parsed = ThemePaletteOverrides.parseHex(value);
                  if (parsed != null) widget.onPreview(parsed);
                  Navigator.pop(context, true);
                },
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  _DialogActionButton(
                    label: z ? '恢复默认' : 'Reset',
                    onTap: () => _setColor(widget.defaultColor),
                  ),
                  const Spacer(),
                  _DialogActionButton(
                    label: z ? '取消' : 'Cancel',
                    onTap: () => Navigator.pop(context, false),
                  ),
                  const SizedBox(width: 6),
                  _DialogActionButton(
                    label: z ? '完成' : 'Apply',
                    primary: true,
                    onTap: () {
                      final parsed = ThemePaletteOverrides.parseHex(
                        _hexController.text,
                      );
                      if (parsed != null) widget.onPreview(parsed);
                      Navigator.pop(context, true);
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

class _SatValBox extends StatelessWidget {
  const _SatValBox({required this.hsv, required this.onChanged});

  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;

  void _handle(Offset local, Size size) {
    final s = (local.dx / size.width).clamp(0.0, 1.0);
    final v = (1.0 - local.dy / size.height).clamp(0.0, 1.0);
    onChanged(hsv.withSaturation(s).withValue(v));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          onPanDown: (d) => _handle(d.localPosition, size),
          onPanUpdate: (d) => _handle(d.localPosition, size),
          child: MouseRegion(
            cursor: SystemMouseCursors.precise,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: CustomPaint(
                size: size,
                painter: _SatValPainter(hsv),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SatValPainter extends CustomPainter {
  const _SatValPainter(this.hsv);

  final HSVColor hsv;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final pureHue = HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor();
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [Colors.white, pureHue],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black],
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
        ..color = Colors.black.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
    canvas.drawCircle(
      knob,
      6.0,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0,
    );
  }

  @override
  bool shouldRepaint(_SatValPainter oldDelegate) => oldDelegate.hsv != hsv;
}

class _HueStrip extends StatelessWidget {
  const _HueStrip({required this.hue, required this.onChanged});

  final double hue;
  final ValueChanged<double> onChanged;

  void _handle(Offset local, double width) {
    final h = ((local.dx / width).clamp(0.0, 1.0) * 360.0).clamp(0.0, 359.9);
    onChanged(h);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          onPanDown: (d) => _handle(d.localPosition, width),
          onPanUpdate: (d) => _handle(d.localPosition, width),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: CustomPaint(
              size: Size(width, constraints.maxHeight),
              painter: _HueStripPainter(hue),
            ),
          ),
        );
      },
    );
  }
}

class _HueStripPainter extends CustomPainter {
  const _HueStripPainter(this.hue);

  final double hue;

  @override
  void paint(Canvas canvas, Size size) {
    final track = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 3, size.width, size.height - 6),
      const Radius.circular(999),
    );
    canvas.drawRRect(
      track,
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
        ).createShader(Offset.zero & size),
    );
    final x = (hue / 360.0).clamp(0.0, 1.0) * size.width;
    final center = Offset(x.clamp(6.0, size.width - 6.0), size.height / 2);
    canvas.drawCircle(
      center,
      6.5,
      Paint()..color = Colors.black.withValues(alpha: 0.28),
    );
    canvas.drawCircle(center, 5.5, Paint()..color = Colors.white);
    canvas.drawCircle(
      center,
      3.5,
      Paint()..color = HSVColor.fromAHSV(1, hue, 1, 1).toColor(),
    );
  }

  @override
  bool shouldRepaint(_HueStripPainter oldDelegate) => oldDelegate.hue != hue;
}
