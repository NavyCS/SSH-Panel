/// Regression tests for the shadcn `ShadSelect` null-value contract.
///
/// `ShadSelect` dereferences its placeholder when the selected value is null:
///
/// ```dart
/// assert(widget.placeholder != null,
///        'placeholder must not be null when value is null');
/// result = widget.placeholder!;
/// ```
///
/// The assert only fires in debug. A release build goes straight to the `!`
/// and throws "Null check operator used on a null value" while building, which
/// surfaces as an unhandled FlutterError on startup rather than as a visibly
/// empty select.
///
/// The Service tab's Startup Type select has a genuinely nullable value: the
/// SCM query returns null when OpenSSH is absent or refuses. It shipped without
/// a placeholder, so the app threw on launch on machines where that query
/// failed while working fine on others. These tests pin the requirement.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:ssh_panel/services/ssh_service.dart';

Widget harness(Widget child) =>
    ShadApp(home: Scaffold(body: Center(child: child)));

/// `selectedOptionBuilder` is mandatory in shadcn, and it is generic in the
/// option type, so this is generic too and every select here shares it.
Widget _selectedOptionBuilder<T>(BuildContext context, T value) =>
    Text(value.toString());

List<ShadOption<String>> get _stringOptions => [
      const ShadOption<String>(value: 'a', child: Text('A')),
    ];

List<ShadOption<StartupType>> get _startupTypeOptions => [
      for (final type in StartupType.values)
        ShadOption<StartupType>(value: type, child: Text(type.name)),
    ];

void main() {
  group('ShadSelect with a null value', () {
    testWidgets('throws when no placeholder is supplied', (tester) async {
      // The failure the app actually hit. Asserted so the contract is known
      // rather than rediscovered from a startup crash.
      await tester.pumpWidget(harness(
        const ShadSelect<String>(
          initialValue: null,
          selectedOptionBuilder: _selectedOptionBuilder,
          options: [ShadOption<String>(value: 'a', child: Text('A'))],
        ),
      ));

      expect(tester.takeException(), isNotNull);
    });

    testWidgets('renders the placeholder when one is supplied', (tester) async {
      // The shape the Service tab now uses: a nullable value plus a
      // placeholder, so "could not be determined" is shown instead of
      // crashing.
      await tester.pumpWidget(harness(
        ShadSelect<String>(
          initialValue: null,
          placeholder: const Text('Unknown'),
          selectedOptionBuilder: _selectedOptionBuilder,
          options: _stringOptions,
        ),
      ));

      expect(tester.takeException(), isNull);
      expect(find.text('Unknown'), findsOneWidget);
    });

    testWidgets('a non-null value needs no placeholder', (tester) async {
      // Guards the opposite mistake: adding a placeholder everywhere would make
      // a populated select render the placeholder text instead.
      await tester.pumpWidget(harness(
        const ShadSelect<String>(
          initialValue: 'a',
          selectedOptionBuilder: _selectedOptionBuilder,
          options: [ShadOption<String>(value: 'a', child: Text('A'))],
        ),
      ));

      expect(tester.takeException(), isNull);
      expect(find.text('Unknown'), findsNothing);
    });
  });

  group('the Service tab configuration', () {
    testWidgets('survives a null StartupType with a placeholder',
        (tester) async {
      // Exactly what the Service tab builds when the SCM query returns null.
      await tester.pumpWidget(harness(
        ShadSelect<StartupType>(
          initialValue: null,
          placeholder: const Text('Unknown'),
          selectedOptionBuilder: _selectedOptionBuilder,
          options: _startupTypeOptions,
        ),
      ));

      expect(tester.takeException(), isNull);
      expect(find.text('Unknown'), findsOneWidget);
    });

    testWidgets('shows the real value when the query succeeds',
        (tester) async {
      await tester.pumpWidget(harness(
        ShadSelect<StartupType>(
          initialValue: StartupType.manual,
          placeholder: const Text('Unknown'),
          selectedOptionBuilder: _selectedOptionBuilder,
          options: _startupTypeOptions,
        ),
      ));

      expect(tester.takeException(), isNull);
      // The shared builder renders value.toString(), so an enum shows as
      // 'StartupType.manual'; what matters is that it shows the value rather
      // than the placeholder.
      expect(find.textContaining('manual'), findsOneWidget);
      expect(find.text('Unknown'), findsNothing);
    });
  });
}