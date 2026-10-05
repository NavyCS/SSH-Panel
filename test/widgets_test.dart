/// Widget tests for the shared UI extracted out of the 2,452-line main.dart.
///
/// These cover behaviour that was silently wrong before the extraction and that
/// a build or analyzer pass cannot catch: pluralisation, and the accessibility
/// semantics of a disabled control.
library;

import 'dart:ui' show SemanticsFlag;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:ssh_panel/shared/widgets/action_row.dart';
import 'package:ssh_panel/shared/widgets/disabled_action_wrapper.dart';
import 'package:ssh_panel/shared/widgets/host_status_badge.dart';

/// Mounts [child] inside a real shadcn app so ShadTheme.of(context) resolves.
Widget harness(Widget child) => ShadApp(home: Scaffold(body: Center(child: child)));

void main() {
  group('HostStatusBadge', () {
    testWidgets('pluralises a single key without the key(s) pattern',
        (tester) async {
      await tester.pumpWidget(harness(const HostStatusBadge(status: 'ssh-ed25519')));
      expect(find.text('1 key found'), findsOneWidget);
      expect(find.textContaining('key(s)'), findsNothing);
    });

    testWidgets('pluralises several keys', (tester) async {
      await tester.pumpWidget(harness(
        const HostStatusBadge(status: 'ssh-ed25519, ssh-rsa, ecdsa-sha2-nistp256'),
      ));
      expect(find.text('3 keys found'), findsOneWidget);
    });

    testWidgets('shows Unreachable verbatim', (tester) async {
      await tester.pumpWidget(
          harness(const HostStatusBadge(status: 'Unreachable')));
      expect(find.text('Unreachable'), findsOneWidget);
    });

    testWidgets('surfaces an error status instead of counting it as keys',
        (tester) async {
      // The old code split on ', ' unconditionally, so a status string that
      // was not a key list rendered as "1 key found" regardless of meaning.
      await tester.pumpWidget(
          harness(const HostStatusBadge(status: 'Error: connection refused')));
      expect(find.textContaining('key'), findsNothing);
    });

    testWidgets('builds on a degenerate empty status', (tester) async {
      await tester
          .pumpWidget(harness(const HostStatusBadge(status: '')));
      expect(tester.takeException(), isNull);
    });
  });

  group('RowAction', () {
    test('is enabled only when a callback is supplied', () {
      expect(const RowAction(label: 'a', onPressed: null, enabledTooltip: 'x')
          .isEnabled, isFalse);
      expect(
        const RowAction(label: 'a', onPressed: _noop, enabledTooltip: 'x')
            .isEnabled,
        isTrue,
      );
    });

    test('shows the enabled tooltip when available', () {
      const action = RowAction(
        label: 'Load',
        onPressed: _noop,
        enabledTooltip: 'Load id_ed25519 into ssh-agent',
      );
      expect(action.tooltip, 'Load id_ed25519 into ssh-agent');
    });

    test('prefers the disabled reason over the enabled tooltip', () {
      // Falling back to the enabled tooltip would tell the user to do
      // something that is currently impossible.
      const action = RowAction(
        label: 'Load',
        onPressed: null,
        enabledTooltip: 'Load key into ssh-agent',
        disabledTooltip: 'Start the ssh-agent service first',
      );
      expect(action.tooltip, 'Start the ssh-agent service first');
    });

    test('falls back to the enabled tooltip when no reason is given', () {
      const action = RowAction(
        label: 'Delete',
        onPressed: null,
        enabledTooltip: 'Delete the key',
      );
      expect(action.tooltip, 'Delete the key');
    });
  });

  group('DisabledActionWrapper', () {
    testWidgets('marks the subtree as disabled for screen readers',
        (tester) async {
      // The original wrapper left Semantics(button: true) with no
      // enabled:false, so this control announced as live but did nothing.
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(harness(
        const DisabledActionWrapper(
          enabled: false,
          tooltip: 'Start the ssh-agent service first',
          child: Text('Load'),
        ),
      ));

      final node = tester.getSemantics(find.text('Load'));
      // hasFlag is deprecated in favour of flagsCollection, whose Tristate type is
// not exported for direct comparison from this package. The deprecated call is
// kept deliberately: it asserts the semantics flag this wrapper exists to set.
// ignore: deprecated_member_use
      expect(
        // ignore: deprecated_member_use
        node.hasFlag(SemanticsFlag.isEnabled),
        isFalse,
        reason: 'a disabled control must not announce itself as enabled',
      );
      expect(node.label, contains('Start the ssh-agent service first'));
      handle.dispose();
    });

    testWidgets('marks the subtree as enabled when available', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(harness(
        const DisabledActionWrapper(
          enabled: true,
          tooltip: 'Load the key',
          child: Text('Load'),
        ),
      ));

      final node = tester.getSemantics(find.text('Load'));
      // ignore: deprecated_member_use
      expect(node.hasFlag(SemanticsFlag.isEnabled), isTrue);
      handle.dispose();
    });

    testWidgets('does not swallow pointer events when disabled', (tester) async {
      var taps = 0;
      await tester.pumpWidget(harness(
        DisabledActionWrapper(
          enabled: false,
          tooltip: 'Unavailable',
          child: TextButton(
            onPressed: () => taps++,
            child: const Text('Load'),
          ),
        ),
      ));

      await tester.tap(find.text('Load'), warnIfMissed: false);
      await tester.pump();
      expect(taps, 0);
    });
  });

  group('ActionRow', () {
    testWidgets('renders every action label', (tester) async {
      await tester.pumpWidget(harness(
        const ActionRow(
          actions: [
            RowAction(label: 'View', onPressed: null, enabledTooltip: 'v'),
            RowAction(label: 'Load', onPressed: _noop, enabledTooltip: 'l'),
            RowAction(label: 'Unload', onPressed: null, enabledTooltip: 'u'),
            RowAction(label: 'Delete', onPressed: null, enabledTooltip: 'd'),
          ],
        ),
      ));

      for (final label in ['View', 'Load', 'Unload', 'Delete']) {
        expect(find.text(label), findsOneWidget);
      }
    });

    testWidgets('gives each action a stable key', (tester) async {
      await tester.pumpWidget(harness(
        const ActionRow(
          actions: [
            RowAction(label: 'View', onPressed: null, enabledTooltip: 'v'),
            RowAction(label: 'Load', onPressed: null, enabledTooltip: 'l'),
          ],
        ),
      ));

      // Identity by label is what stops a row gaining/losing an action from
      // rebuilding and resetting every later row.
      expect(find.byKey(const ValueKey('View')), findsOneWidget);
      expect(find.byKey(const ValueKey('Load')), findsOneWidget);
    });
  });
}

void _noop() {}
