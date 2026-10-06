/// Tests for the title-bar attribution widget.
///
/// The credit sits in a [Row] next to a control that only sometimes exists
/// (Admin Mode / Restart in Admin Mode), so the two things worth pinning down
/// here are that it can shrink, and that the link announces itself as a link
/// rather than as another button. Hover, focus styling and the click itself
/// are deliberately not asserted: this harness does not simulate hover
/// reliably, so those are confirmed in the running app instead.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:ssh_panel/shared/widgets/app_credit.dart';

Widget harness(Widget child) =>
    ShadApp(home: Scaffold(body: Center(child: child)));

/// The title-bar shape from `main.dart`: a leading cluster, then an end-aligned
/// row holding a Settings-sized control, a gap, and the credit as a loose
/// `Flexible`. [available] is how much width the credit is competing for.
Widget _titleBar(double available) => ShadApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 30 + 12 + available,
            child: Row(
              children: [
                const SizedBox(width: 30),
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      const SizedBox(width: 30),
                      const SizedBox(width: 12),
                      Flexible(child: const AppCredit()),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

void main() {
  group('AppCredit', () {
    test('points the link at a named constant, not a literal in the widget',
        () {
      expect(AppCredit.githubUrl, 'https://github.com');
    });

    testWidgets('renders both lines', (tester) async {
      await tester.pumpWidget(harness(const AppCredit()));

      expect(find.text('Made with ❤️ & 🤖'), findsOneWidget);
      expect(find.text('by navy_cs (${AppCredit.versionLabel}): '),
          findsOneWidget);
      expect(find.text('github'), findsOneWidget);
    });

    testWidgets('the link sits on the same line as the attribution',
        (tester) async {
      await tester.pumpWidget(harness(const AppCredit()));

      // "by navy_cs (v1.0): github" reads as one sentence, so the two halves
      // have to share a baseline rather than stacking.
      final attribution = tester.getRect(
        find.text('by navy_cs (${AppCredit.versionLabel}): '),
      );
      final link = tester.getRect(find.text('github'));

      expect(
        link.left,
        greaterThanOrEqualTo(attribution.right - 0.5),
        reason: 'the link must follow the attribution, not overlap it',
      );
      expect(
        link.center.dy,
        closeTo(attribution.center.dy, 2.0),
        reason: 'same line means a shared vertical centre',
      );
    });

    test('the shown version matches the one in pubspec.yaml', () {
      // One source of truth. pubspec says `version: 1.0.0+1`; the credit shows
      // major.minor, dropping the build number and the patch level. Bumping the
      // app version without updating the credit used to be a silent drift, and
      // this fails instead.
      final pubspec = File('pubspec.yaml');
      expect(
        pubspec.existsSync(),
        isTrue,
        reason: 'the test runs with the project root as its working directory',
      );

      final match = RegExp(r'^version:\s*(\S+)$', multiLine: true)
          .firstMatch(pubspec.readAsStringSync());
      expect(match, isNotNull, reason: 'pubspec must declare a version');

      // `1.0.0+1` -> `1.0`: drop the build number, then keep major.minor.
      final withoutBuild = match!.group(1)!.split('+').first;
      final parts = withoutBuild.split('.');
      expect(parts.length, greaterThanOrEqualTo(2));
      final expected = 'v${parts[0]}.${parts[1]}';

      expect(
        AppCredit.versionLabel,
        expected,
        reason: 'pubspec declares $withoutBuild, so the credit should read '
            '$expected. Update AppCredit.versionLabel when you bump the app.',
      );
    });

    testWidgets('announces the link as a link, with a useful label',
        (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(harness(const AppCredit()));

      final node = tester.semantics
          .find(find.bySemanticsLabel('Open the project on GitHub'));
      expect(node.label, 'Open the project on GitHub');
      expect(node.flagsCollection.isLink, isTrue);

      handle.dispose();
    });

    testWidgets('shrinks to the space it is given instead of overflowing it',
        (tester) async {
      // The same shape the title bar uses: a leading cluster, then an
      // end-aligned row holding the Settings stub and the credit.
      const stub = 60.0;
      const button = 30.0;
      const gap = 12.0;
      const available = 150.0;
      const total = stub + button + gap + available;

      await tester.pumpWidget(
        ShadApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: total,
                child: Row(
                  children: [
                    const SizedBox(width: stub),
                    Expanded(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: const [
                          SizedBox(width: button),
                          SizedBox(width: gap),
                          Flexible(child: AppCredit()),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byType(AppCredit)).width,
        lessThanOrEqualTo(available),
        reason: 'the credit must lay out inside the space it was handed',
      );
      expect(
        tester.getRect(find.byType(AppCredit)).right,
        closeTo((800 + total) / 2, 0.5),
        reason: 'the credit must stay flush against the right-hand end',
      );
    });

    testWidgets('keeps its height bounded as the window narrows', (tester) async {
      // This is the one that matters. The credit is allowed to lose width, but
      // not height: the word `github` has no cap of its own, so once the window
      // got narrow enough it broke letter-by-letter and the title bar grew from
      // 38px to 122px tall. A test that only checked a comfortable width never
      // saw it.
      final heights = <double>[];
      for (final available in [400.0, 150.0, 90.0, 60.0, 40.0]) {
        await tester.pumpWidget(_titleBar(available));

        expect(tester.takeException(), isNull,
            reason: 'no overflow at $available px');
        heights.add(tester.getSize(find.byType(AppCredit)).height);
      }

      debugPrint('credit heights by available width: $heights');
      // Narrowing may only ever *add* lines, and never more than the one line
      // line1 is allowed to wrap onto. The runaway this test was written for
      // was +84px between two widths; +14 is the whole legitimate range.
      for (var i = 1; i < heights.length; i++) {
        expect(heights[i], greaterThanOrEqualTo(heights[i - 1]),
            reason: 'narrowing must not shrink the credit. Measured: '
                '$heights');
        expect(heights[i] - heights[i - 1], lessThanOrEqualTo(14),
            reason: 'one wrapped line per step is the entire budget. '
                'Measured: $heights');
      }
      // Absolute cap: 52px of content (two lines of credit text, a gap, one
      // line of link) plus the container's 2 * 4 padding and 2px border = 62,
      // with 2px of slack. Anything past 64 means the box, not the text, is
      // growing.
      expect(
        heights.every((h) => h <= 64),
        isTrue,
        reason: 'the credit may shrink in width, never in height. Measured: '
            '$heights',
      );
      // The link itself must never wrap to more than one line.
      expect(
        tester.getSize(find.text('github')).height,
        lessThanOrEqualTo(16),
        reason: 'a wrapped link is what turned the bar into a column',
      );
    });

    testWidgets('adds only its documented box, when one line fits',
        (tester) async {
      // 700px of space is roomy enough for the whole credit on one line even
      // with the test font, which is wider than Geist: the matrix above never
      // sees the unwrapped case, so without this the container could double
      // its padding and every height in it would stay flat and green.
      await tester.pumpWidget(_titleBar(700));

      expect(tester.takeException(), isNull);
      // 38px of content (line + gap + link box) + padding (vertical already
      // counts top and bottom) + 2px of border.
      expect(
        tester.getSize(find.byType(AppCredit)).height,
        38 + AppCredit.boxPadding.vertical + 2,
        reason: 'the container may cost its own padding, nothing more; '
            'otherwise the title bar grows with it',
      );
    });

    testWidgets('paints the box from the theme, not from literals',
        (tester) async {
      await tester.pumpWidget(harness(const AppCredit()));

      final theme = ShadTheme.of(tester.element(find.byType(AppCredit)));
      final container = tester.widget<Container>(
        find
            .descendant(
                of: find.byType(AppCredit), matching: find.byType(Container))
            .first,
      );
      final decoration = container.decoration! as BoxDecoration;

      expect(decoration.color, theme.colorScheme.card,
          reason: 'same fill as the section cards');
      expect((decoration.border as Border).top.color, theme.colorScheme.border,
          reason: 'same hairline as the section cards');
      expect(decoration.borderRadius, theme.cardTheme.radius ?? theme.radius,
          reason: 'same radius as the section cards');
      expect(container.padding, AppCredit.boxPadding);
    });

    testWidgets('is reachable with the keyboard', (tester) async {
      await tester.pumpWidget(harness(const AppCredit()));

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);

      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'AppCredit.github',
        reason: 'Tab must land on the link, not skip past it',
      );
    });
  });
}
