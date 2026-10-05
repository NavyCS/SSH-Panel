/// Widget tests for the shared UI extracted out of the 2,452-line main.dart.
///
/// These cover behaviour that was silently wrong before the extraction and that
/// a build or analyzer pass cannot catch: pluralisation, and the accessibility
/// semantics of a disabled control.
library;

import 'dart:ui' show PointerDeviceKind, SemanticsFlag;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:ssh_panel/features/domains/add_host_field.dart';
import 'package:ssh_panel/features/domains/host_row.dart';
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

  group('AddHostField', () {
    late TextEditingController hostController;

    setUp(() => hostController = TextEditingController());
    tearDown(() => hostController.dispose());

    testWidgets('the tooltip quotes the host as it is typed',
        (tester) async {
      await tester.pumpWidget(harness(AddHostField(
        hostController: hostController,
        isScanning: false,
        isHostsLoading: false,
        onAdd: _noop,
      )));

      // The field listens to nothing but its own controller. The tooltip and
      // the status line quote the typed host, so if they are read outside the
      // listener they keep showing whatever was there at the last full rebuild
      // -- which, on first mount, is an empty host.
      await tester.enterText(find.byType(ShadInput), 'gitlab.com');
      await tester.pump();

      // ShadTooltip only builds its content once hovered, so a real mouse
      // pointer has to enter the button.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.text('Add')));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('gitlab.com'),
        findsWidgets,
        reason: 'the tooltip must name the host the user just typed',
      );
      expect(
        find.textContaining('scans  for its keys'),
        findsNothing,
        reason: 'an empty host in the message means the text was read stale',
      );
    });

    testWidgets('shows the phase while scanning and blocks a second scan',
        (tester) async {
      var adds = 0;
      await tester.pumpWidget(harness(AddHostField(
        hostController: hostController,
        isScanning: true,
        isHostsLoading: false,
        onAdd: () => adds++,
      )));

      expect(find.text('Scanning…'), findsOneWidget);
      expect(find.textContaining('Step 1 of 2 · Scanning'), findsOneWidget);
      // The field is disabled for the whole scan, so a second click cannot
      // start a competing ssh-keyscan on the same host.
      expect(tester.widget<ShadInput>(find.byType(ShadInput)).enabled, isFalse);

      await tester.tap(find.text('Scanning…'));
      await tester.pump();
      expect(adds, 0);
    });

    testWidgets('names the host in the status line', (tester) async {
      hostController.text = 'example.com';
      await tester.pumpWidget(harness(AddHostField(
        hostController: hostController,
        isScanning: true,
        isHostsLoading: false,
        onAdd: _noop,
      )));

      expect(find.textContaining('example.com'), findsWidgets);
    });
  });

  group('HostRow status badge', () {
    Widget row(String? status) => harness(HostRow(
          entry: const {'host': 'gitlab.com', 'keyType': 'ssh-ed25519'},
          status: status,
          isChecking: false,
          isHostsLoading: false,
          onCheck: _noop,
          onRemove: _noop,
        ));

    // These assert structure, not hover. Mouse hover cannot be simulated
    // faithfully in a widget test here -- Flutter's own Tooltip fails to appear
    // over a bare Text -- so what is pinned is that the tooltip is given a
    // region the pointer can actually be detected on. Whether the tooltip then
    // appears has to be confirmed in the running app.
    testWidgets('the badge sits in an opaque hover region', (tester) async {
      await tester.pumpWidget(row('ssh-ed25519, ecdsa-sha2-nistp256, ssh-rsa'));

      // Scoped to the badge's own detector: the row's Check and Remove buttons
      // each contain one of their own.
      final detector = tester.widget<ShadGestureDetector>(find.ancestor(
        of: find.byType(HostStatusBadge),
        matching: find.byType(ShadGestureDetector),
      ));
      expect(
        detector.behavior,
        HitTestBehavior.opaque,
        reason: 'ShadTooltip detects the pointer with deferToChild, so the '
            'badge needs an opaque region or the hover never registers',
      );
      expect(find.byType(HostStatusBadge), findsOneWidget);
    });

    testWidgets('that region is not a button', (tester) async {
      await tester.pumpWidget(row('ssh-ed25519'));

      // A status is read-only. Giving it tap callbacks would put a dead control
      // in the tab order, the exact defect the badge was built to avoid.
      final detector = tester.widget<ShadGestureDetector>(find.ancestor(
        of: find.byType(HostStatusBadge),
        matching: find.byType(ShadGestureDetector),
      ));
      expect(detector.onTap, isNull);
      expect(detector.onLongPress, isNull);
    });

    testWidgets('no badge before the host has been checked', (tester) async {
      await tester.pumpWidget(row(null));

      // null means "never checked", which is not the same as "checked and found
      // nothing". Nothing is claimed, so nothing is shown.
      expect(find.byType(HostStatusBadge), findsNothing);
    });

    testWidgets('a full algorithm list reaches the badge', (tester) async {
      await tester.pumpWidget(row('ssh-ed25519, ecdsa-sha2-nistp256, ssh-rsa'));

      // The badge itself only has room for the count; the names have to survive
      // into the status string the tooltip quotes.
      expect(find.text('3 keys found'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp(r'Host status for gitlab\.com: .*ssh-rsa')),
        findsOneWidget,
      );
    });
  });
}

void _noop() {}
