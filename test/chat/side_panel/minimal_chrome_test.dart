import 'package:baocode/chat/chat_screen.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/side_panel/side_panel_controller.dart';
import 'package:baocode/chat/side_panel/side_panel_view.dart';
import 'package:baocode/chat/widgets/context_meter.dart';
import 'package:baocode/ide/file_service.dart';
import 'package:baocode/ide/ide_notifications.dart';
import 'package:baocode/l10n/app_localizations.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'AgentSidePanel persists removable & addable sections and keeps at least one active',
    () {
      Map<String, Object?>? saved;
      final panel = AgentSidePanel(onSave: () {});
      addTearDown(panel.dispose);

      expect(panel.enabledSections, [
        SidePanelSection.files,
        SidePanelSection.changes,
        SidePanelSection.terminal,
        SidePanelSection.usage,
      ]);

      final session = Object();
      panel.showSection(session, SidePanelSection.terminal);
      expect(panel.resolveShownSection(panel.tabsOf(session)), SidePanelSection.terminal);

      // Remove terminal and usage -> active section automatically shifts to first remaining.
      panel.setSectionEnabled(SidePanelSection.terminal, false, conversation: session);
      panel.setSectionEnabled(SidePanelSection.usage, false, conversation: session);
      expect(panel.enabledSections, [
        SidePanelSection.files,
        SidePanelSection.changes,
      ]);
      expect(panel.resolveShownSection(panel.tabsOf(session)), SidePanelSection.files);

      // Remove files -> only changes remains; attempting to remove last tab is ignored.
      panel.setSectionEnabled(SidePanelSection.files, false, conversation: session);
      expect(panel.enabledSections, [SidePanelSection.changes]);
      panel.setSectionEnabled(SidePanelSection.changes, false, conversation: session);
      expect(panel.enabledSections, [SidePanelSection.changes]);

      // Re-add usage and verify JSON round-trip.
      panel.setSectionEnabled(SidePanelSection.usage, true, conversation: session);
      expect(panel.enabledSections, [
        SidePanelSection.changes,
        SidePanelSection.usage,
      ]);
      expect(panel.resolveShownSection(panel.tabsOf(session)), SidePanelSection.usage);

      saved = panel.toJson();
      final restored = AgentSidePanel(state: saved);
      addTearDown(restored.dispose);
      expect(restored.enabledSections, [
        SidePanelSection.changes,
        SidePanelSection.usage,
      ]);
      expect(restored.sectionsCustomized, isTrue);

      restored.resetEnabledSections();
      expect(restored.enabledSections, alwaysShownSections);
      expect(restored.sectionsCustomized, isFalse);
    },
  );

  testWidgets(
    'Collapsed SidePanelRail stays hidden (opacity 0) until hovered, and bottom foot shows only ContextMeter',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final panel = AgentSidePanel();
      addTearDown(panel.dispose);
      final session = ChatSession();
      addTearDown(session.dispose);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: buildAppTheme(),
          home: AgentSidePanelArea(
            panel: panel,
            rail: SidePanelRail(
              panel: panel,
              session: session,
              onSelect: (s) => panel.showSection(session, s),
            ),
            builder: (_) => AgentSidePanelView(
              panel: panel,
              session: session,
              files: IdeFileService('/tmp'),
              notifications: IdeNotifications(),
            ),
            child: ChatScreen(
              session: session,
              island: AppColors.conversationSurface,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // At rest when collapsed, the floating rail has opacity 0.0.
      final animatedOpacityFinder = find.ancestor(
        of: find.byType(SidePanelRail),
        matching: find.byType(AnimatedOpacity),
      );
      expect(
        tester.widget<AnimatedOpacity>(animatedOpacityFinder.first).opacity,
        0.0,
      );

      // Move mouse over the rail area -> reveals smoothly (opacity 1.0).
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      final railCenter = tester.getCenter(find.byType(SidePanelRail));
      await gesture.moveTo(railCenter);
      await tester.pumpAndSettle();

      expect(
        tester.widget<AnimatedOpacity>(animatedOpacityFinder.first).opacity,
        1.0,
      );

      // Move mouse away -> hides again (opacity 0.0).
      await gesture.moveTo(const Offset(300, 300));
      await tester.pumpAndSettle();
      expect(
        tester.widget<AnimatedOpacity>(animatedOpacityFinder.first).opacity,
        0.0,
      );

      // Bottom status row shows ContextMeter and no extra speed/folder clutter.
      expect(find.byType(ContextMeter), findsOneWidget);
      expect(find.textContaining('今日'), findsNothing);
    },
  );
}
