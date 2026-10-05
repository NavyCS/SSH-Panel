/// Tests for the pluralisation helper and the agent status badge.
///
/// Both replace things that were simply wrong: card descriptions read
/// "1 file(s) in ~/.ssh", and the Running/Stopped badges were drawn identically
/// so the state gave nothing away at a glance.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:ssh_panel/services/ssh_service.dart';
import 'package:ssh_panel/shared/plural.dart';
import 'package:ssh_panel/shared/widgets/agent_status_badge.dart';

Widget harness(Widget child) => ShadApp(home: Scaffold(body: Center(child: child)));

void main() {
  group('plural', () {
    test('uses the singular for exactly one', () {
      // The case that mattered: "1 file(s)" was what the card used to show.
      expect(plural(1, 'file'), '1 file');
      expect(plural(1, 'authorized key'), '1 authorized key');
    });

    test('uses the plural for zero', () {
      expect(plural(0, 'file'), '0 files');
      expect(plural(0, 'key'), '0 keys');
      expect(plural(0, 'host'), '0 hosts');
    });

    test('uses the plural for two and above', () {
      expect(plural(2, 'file'), '2 files');
      expect(plural(3, 'authorized key'), '3 authorized keys');
      expect(plural(17, 'host'), '17 hosts');
    });

    test('accepts an irregular plural', () {
      // 'key(s)' style pluralisation breaks on words like this, which is why
      // the override exists.
      expect(plural(1, 'entry', 'entries'), '1 entry');
      expect(plural(2, 'entry', 'entries'), '2 entries');
      expect(plural(0, 'entry', 'entries'), '0 entries');
    });

    test('never emits the (s) pattern', () {
      for (var n = 0; n < 6; n++) {
        expect(plural(n, 'key'), isNot(contains('(s)')));
      }
    });
  });

  group('AgentStatusBadge', () {
    testWidgets('labels every service state', (tester) async {
      for (final state in SshServiceState.values) {
        await tester.pumpWidget(harness(AgentStatusBadge(state: state)));
        expect(
          find.text(ServiceControllerStatusLabels.labelFor(state)),
          findsOneWidget,
          reason: 'no label for ${state.name}',
        );
      }
    });

    testWidgets('shows Unknown when the state is null', (tester) async {
      await tester.pumpWidget(harness(const AgentStatusBadge(state: null)));
      expect(find.text('Unknown'), findsOneWidget);
    });

    testWidgets('running is drawn differently from stopped', (tester) async {
      // The defect: both were the same neutral pill, so the row carried no
      // signal. Compare the rendered badge variants rather than the text.
      Future<ShadBadge> variantOf(SshServiceState state) async {
        await tester.pumpWidget(harness(AgentStatusBadge(state: state)));
        return tester.widget<ShadBadge>(find.byType(ShadBadge));
      }

      final running = await variantOf(SshServiceState.running);
      final stopped = await variantOf(SshServiceState.stopped);

      expect(running.variant, isNot(stopped.variant),
          reason: 'Running and Stopped must be visually distinguishable');
    });

    testWidgets('transition states differ from settled ones', (tester) async {
      Future<ShadBadge> variantOf(SshServiceState state) async {
        await tester.pumpWidget(harness(AgentStatusBadge(state: state)));
        return tester.widget<ShadBadge>(find.byType(ShadBadge));
      }

      final running = await variantOf(SshServiceState.running);
      final starting = await variantOf(SshServiceState.startPending);
      expect(running.variant, isNot(starting.variant));

      // A transitional state should also stand out from stopped.
      final stopped = await variantOf(SshServiceState.stopped);
      expect(starting.variant, isNot(stopped.variant));
    });

    testWidgets('announces the state to screen readers', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
          harness(const AgentStatusBadge(state: SshServiceState.running)));

      expect(find.bySemanticsLabel('Agent status: Running'), findsOneWidget);
      handle.dispose();
    });
  });
}

/// Local mirror of the controller's label mapping, kept independent so this
/// test asserts the strings the badge is expected to render.
class ServiceControllerStatusLabels {
  ServiceControllerStatusLabels._();

  static String labelFor(SshServiceState state) => switch (state) {
        SshServiceState.running => 'Running',
        SshServiceState.stopped => 'Stopped',
        SshServiceState.startPending => 'Start Pending',
        SshServiceState.stopPending => 'Stop Pending',
        SshServiceState.continuePending => 'Continue Pending',
        SshServiceState.paused => 'Paused',
        SshServiceState.unknown => 'Unknown',
      };
}