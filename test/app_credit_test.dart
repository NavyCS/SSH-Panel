/// Tests for the title-bar attribution widget.
///
/// The credit sits in a [Row] next to a control that only sometimes exists
/// (Admin Mode / Restart in Admin Mode), so the two things worth pinning down
/// here are that it can shrink, and that the link announces itself as a link
/// rather than as another button. Hover, focus styling and the click itself
/// are deliberately not asserted: this harness does not simulate hover
/// reliably, so those are confirmed in the running app instead.
library;

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

      expect(find.text('Made with ❤️ & 🤖 by navy_cs'), findsOneWidget);
      expect(find.text('github'), findsOneWidget);
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
        tester.getSize(find.text('Made with ❤️ & 🤖 by navy_cs')).width,
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
      // Two lines of credit text, a gap, and one line of link: the height is
      // the same whatever the width.
      expect(
        heights.every((h) => h <= 56),
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
