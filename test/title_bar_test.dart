/// Tests for the title bar.
///
/// Extracted from `main.dart` so it could be measured: the app name and the
/// right-hand controls overlapped at the minimum window width, and the credit
/// later drifted away from the right edge at the maximum one. Neither was
/// visible in the test suite, for the same reason — see [pumpBar].
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:ssh_panel/shared/widgets/app_credit.dart';
import 'package:ssh_panel/shared/widgets/title_bar.dart';

/// Mounts the bar at a real surface size.
///
/// This matters more than it looks. A bare `Scaffold` in a widget test is
/// 800x600, so a `SizedBox(width: 1240)` inside one is silently clamped to 800.
/// The first version of this file "tested" widths up to 1280 and in fact only
/// ever measured 800 — which is precisely how the gap at the app's real width
/// got through.
Future<void> pumpBar(
  WidgetTester tester,
  double logicalWidth, {
  bool showRestart = false,
  bool admin = false,
}) async {
  const dpr = 1.25;
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = Size(logicalWidth * dpr, 600 * dpr);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(ShadApp(
    home: Scaffold(
      body: Column(
        children: [
          TitleBar(
            isAdminMode: admin,
            showRestartInAdminMode: showRestart,
            onSettingsPressed: () {},
            onRestartElevated: () {},
          ),
        ],
      ),
    ),
  ));
}

/// The window sizes worth testing.
///
/// 800x600 physical is the app's minimum (`windows/runner/main.cpp`,
/// `SetMinimumSize`). This machine reports 125% scaling, so the widest window
/// anyone reaches is about 1240 logical. Both ends matter: the overlap only
/// appeared at the narrow end and the gap only at the wide one.
const widths = <double>[1240.0, 1100.0, 900.0, 800.0, 700.0, 640.0];

void main() {
  group('TitleBar fills its width', () {
    // The gap. The app name was a *loose* flex child, so the part of its share
    // it did not need was never assigned to anything. The group is aligned to
    // the end and nothing follows it, so that remainder piled up as dead space
    // at the right-hand end of the bar: the credit sat 15px short of the window
    // edge at 1240 while every narrower width was correct. Making the name
    // *tight* fills the bar exactly and moves the slack to where a gap belongs,
    // between the name and the controls.
    for (final width in widths) {
      testWidgets('the credit sits flush with the padding at $width', (t) async {
        await pumpBar(t, width, showRestart: true);
        expect(t.takeException(), isNull, reason: 'overflow at $width');

        final bar = t.getRect(find.byType(TitleBar));
        final credit = t.getRect(find.byType(AppCredit));

        expect(
          bar.right - credit.right,
          closeTo(TitleBar.padding.right, 0.5),
          reason: "only the bar's own padding should separate the credit from "
              'the window edge; anything more is unassigned slack',
        );
      });
    }

    testWidgets('the app name still ellipsises rather than being clipped',
        (t) async {
      await pumpBar(t, 640, showRestart: true);

      final title = t.widget<Text>(find.text('SSH Panel'));
      expect(title.maxLines, 1);
      expect(title.overflow, TextOverflow.ellipsis);
      expect(title.softWrap, isFalse);
      expect(
        t.getSize(find.text('SSH Panel')).width,
        greaterThan(0),
        reason: 'the name should be shortened, not collapsed to nothing',
      );
    });
  });

  group('TitleBar lines the credit up with the Settings button', () {
    // The credit is a bordered box next to an icon button, so a height
    // difference between them reads as the box not belonging there. It was 8px
    // taller, which is enough to notice. The two heights are pinned separately
    // as well as against each other: a fix that matched them by growing the
    // button would be a different design decision, and this says so.
    testWidgets('the credit is exactly as tall as the Settings button',
        (t) async {
      await pumpBar(t, 1240, showRestart: true);

      final credit = t.getRect(find.byType(AppCredit));
      final settings = t.getRect(find.byType(ShadIconButton));

      expect(
        credit.height,
        closeTo(settings.height, 0.5),
        reason: 'a bordered box beside a button should not be a different '
            'height; credit=${credit.height} settings=${settings.height}',
      );
    });

    testWidgets('and the height is 40, not whatever the button happens to be',
        (t) async {
      // Guards against the two drifting together on a theme change that grows
      // the button but not the credit, which would again leave a step.
      await pumpBar(t, 1240, showRestart: true);

      expect(t.getRect(find.byType(AppCredit)).height, closeTo(40, 0.5));
      expect(t.getRect(find.byType(ShadIconButton)).height, closeTo(40, 0.5));
    });

    testWidgets('the link keeps a clickable target', (t) async {
      // The height came out of padding, so the target has to be checked rather
      // than assumed. Measured on the GestureDetector, which is the tappable
      // area -- the Text inside it is only 14px and always was, so asserting on
      // the text would have been asserting the wrong thing.
      await pumpBar(t, 1240, showRestart: true);

      final target = t.getRect(
        find
            .ancestor(
              of: find.text('github'),
              matching: find.byType(GestureDetector),
            )
            .first,
      );

      expect(
        target.height,
        greaterThanOrEqualTo(16),
        reason: 'shrinking the box must not shrink the link into a sliver; '
            'target is ${target.height}px tall',
      );
    });

    testWidgets('the credit may still grow when the text wraps', (t) async {
      // Matching the button cannot mean clipping: when the attribution wraps to
      // two lines the box has to get taller, because there is no other honest
      // option. Narrow enough to force the wrap.
      await pumpBar(t, 640, showRestart: true);

      expect(t.takeException(), isNull);
      expect(
        t.getRect(find.byType(AppCredit)).height,
        greaterThan(40),
        reason: 'two lines of attribution need more room than one',
      );
    });
  });

  group('TitleBar does not let its halves collide', () {
    for (final width in widths) {
      testWidgets('no overflow and no overlap at ${width.round()} px', (t) async {
        await pumpBar(t, width, showRestart: true);
        expect(t.takeException(), isNull, reason: 'overflow at $width px');

        final title = t.getRect(find.text('SSH Panel'));
        final control = t.getRect(find.text('Restart elevated'));

        expect(
          title.right,
          lessThanOrEqualTo(control.left + 0.5),
          reason: 'the app name and the control overlapped at $width px: '
              'title right=${title.right}, control left=${control.left}',
        );
      });
    }

    testWidgets('no overlap with the Admin Mode badge', (t) async {
      for (final width in widths) {
        await pumpBar(t, width, admin: true);

        expect(t.takeException(), isNull, reason: 'overflow at $width px');
        final title = t.getRect(find.text('SSH Panel'));
        final badge = t.getRect(find.text('Admin Mode'));
        expect(title.right, lessThanOrEqualTo(badge.left + 0.5));
      }
    });
  });

  group('TitleBar centres the credit', () {
    testWidgets('both credit lines share the box centre line', (t) async {
      await pumpBar(t, 1240);

      final first = t.getRect(find.text('Made with ❤️ & 🤖'));
      final prefix = t.getRect(
        find.text('by navy_cs (${AppCredit.versionLabel}): '),
      );
      final link = t.getRect(find.text('github'));
      final box = t.getRect(find.byType(AppCredit));

      // Measured against the credit's own box, which is what "centred" means
      // here: the widest line defines the box and the others sit centred inside
      // it. The second line needs a few pixels of slack because the link carries
      // 4px of horizontal padding and a 1px border that the bare text does not.
      final secondCentre = (prefix.left + link.right) / 2;

      expect(first.center.dx, closeTo(box.center.dx, 0.5));
      expect(secondCentre, closeTo(box.center.dx, 3.0));
    });

    testWidgets('the credit stays centred once it wraps', (t) async {
      // Narrow enough that the attribution takes two lines: centring has to hold
      // in the wrapped case too, not just when everything fits on one.
      await pumpBar(t, 700);

      expect(t.takeException(), isNull);
      final first = t.getRect(find.text('Made with ❤️ & 🤖'));
      final credit = t.getRect(find.byType(AppCredit));
      expect(first.center.dx, closeTo(credit.center.dx, 0.5));
    });
  });
}
