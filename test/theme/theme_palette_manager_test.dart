import 'dart:io';

import 'package:baocode/chat/chat_screen.dart';
import 'package:baocode/l10n/app_localizations.dart';
import 'package:baocode/platform/data_dir.dart';
import 'package:baocode/settings/user_settings.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:baocode/theme/workbench_theme.dart';
import 'package:baocode/workspace/islands.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    ThemePaletteOverrides.resetForTesting();
    Islands.enabled.value = true;
  });

  test(
    'per-theme palette overrides persist, isolate per theme, and support custom/deleted theme CRUD',
    () async {
      final directory = await Directory.systemTemp.createTemp('byte_palette_');
      addTearDown(() => directory.delete(recursive: true));
      final files = SettingsFiles(DataDirectory(directory.path));
      addTearDown(files.dispose);
      await files.settings.writeText('{\n}\n');

      final previousService = WorkbenchThemeService.instance;
      final service = WorkbenchThemeService();
      WorkbenchThemeService.instance = service;
      addTearDown(() {
        WorkbenchThemeService.instance = previousService;
        service.dispose();
      });

      ThemePaletteOverrides.follow(
        files.settings,
        read: (key) => files.settings[key],
        write: (key, value) => files.settings.update(key, value),
        dataDir: directory.path,
      );

      await service.initialize();
      await service.setColorTheme('Antigravity Light');

      // Base Antigravity Light has distinct sidebar (#EFEEEA) and editor/conversation (#FAF9F5).
      expect(service.colors['editor.background'], const Color(0xFFFAF9F5));
      expect(service.colors['sideBar.background'], const Color(0xFFEFEEEA));
      expect(service.colors['textPreformat.foreground'], const Color(0xFF9E2825));

      // Customize Background, Sidebar, and Inline Code on Antigravity Light.
      await ThemePaletteOverrides.setSlotColor(
        'Antigravity Light',
        ThemePaletteOverrides.slotBackground,
        const Color(0xFFF5F3EC),
      );
      await ThemePaletteOverrides.setSlotColor(
        'Antigravity Light',
        ThemePaletteOverrides.slotSidebar,
        const Color(0xFFE8E5DC),
      );
      await ThemePaletteOverrides.setSlotColor(
        'Antigravity Light',
        ThemePaletteOverrides.slotInlineCode,
        const Color(0xFF7C3AED),
      );

      expect(service.colors['editor.background'], const Color(0xFFF5F3EC));
      expect(service.colors['sideBar.background'], const Color(0xFFE8E5DC));
      expect(service.colors['textPreformat.foreground'], const Color(0xFF7C3AED));
      expect(files.settings[ThemePaletteOverrides.overridesKey], isA<Map>());

      // Switching to Bao Light keeps Bao Light untouched!
      await service.setColorTheme('Bao Light');
      expect(service.colors['editor.background'], isNot(const Color(0xFFF5F3EC)));

      // Create a custom theme baking initial slots, rename it, then delete it.
      final createdId = await service.createCustomTheme(
        name: 'My Warm Studio',
        dark: false,
        baseId: 'Antigravity Light',
        initialSlots: const {
          ThemePaletteOverrides.slotBackground: Color(0xFFFCFBF7),
          ThemePaletteOverrides.slotAccent: Color(0xFF2563EB),
        },
      );
      expect(createdId, 'My Warm Studio');
      expect(service.isCustomTheme('My Warm Studio'), isTrue);
      expect(service.colorThemeId, 'My Warm Studio');
      expect(service.colors['editor.background'], const Color(0xFFFCFBF7));
      expect(service.colors['textLink.foreground'], const Color(0xFF2563EB));

      final renamedId = await service.renameCustomTheme(
        'My Warm Studio',
        'My Warm Studio Pro',
      );
      expect(renamedId, 'My Warm Studio Pro');
      expect(service.isCustomTheme('My Warm Studio Pro'), isTrue);
      expect(service.colorThemeId, 'My Warm Studio Pro');

      final deletedCustom = await service.deleteTheme('My Warm Studio Pro');
      expect(deletedCustom, isTrue);
      expect(service.isCustomTheme('My Warm Studio Pro'), isFalse);

      // Delete a built-in theme and verify it hides & can be restored.
      expect(
        service.colorThemes.any((t) => t.id == 'Solarized Light'),
        isTrue,
      );
      final deletedBuiltin = await service.deleteTheme('Solarized Light');
      expect(deletedBuiltin, isTrue);
      expect(
        service.colorThemes.any((t) => t.id == 'Solarized Light'),
        isFalse,
      );
      expect(service.hasDeletedThemes, isTrue);

      await service.restoreDeletedThemes();
      expect(
        service.colorThemes.any((t) => t.id == 'Solarized Light'),
        isTrue,
      );
      expect(service.hasDeletedThemes, isFalse);
    },
  );

  testWidgets(
    'ChatScreen keeps conversationSurface distinct from sidebarSurface in flush border mode (!Islands.on)',
    (tester) async {
      final previousService = WorkbenchThemeService.instance;
      final service = WorkbenchThemeService();
      WorkbenchThemeService.instance = service;
      addTearDown(() {
        WorkbenchThemeService.instance = previousService;
        service.dispose();
      });

      await service.initialize();
      await service.setColorTheme('Antigravity Light');
      Islands.enabled.value = false;

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: buildAppTheme(),
          home: ChatScreen(island: AppColors.conversationSurface),
        ),
      );
      await tester.pump();

      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
      expect(AppColors.sidebarSurface, const Color(0xFFEFEEEA));
      expect(AppColors.conversationSurface, const Color(0xFFFAF9F5));
      expect(scaffold.backgroundColor, const Color(0xFFFAF9F5));
    },
  );
}
