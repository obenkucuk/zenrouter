import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter_core/zenrouter_core.dart';

import '../support/harness.dart';

class BaseRoute extends RouteTarget {
  BaseRoute(this.id);
  final String id;

  @override
  List<Object?> get props => [id];
}

/// Redirects to a [BaseRoute] that is not a [SpecificRedirectRoute].
class SpecificRedirectRoute extends BaseRoute with RouteRedirect<BaseRoute> {
  SpecificRedirectRoute(super.id, {required this.redirectToId});

  final String redirectToId;
  bool discarded = false;

  @override
  BaseRoute redirect() => BaseRoute(redirectToId);

  @override
  void onDiscard() {
    discarded = true;
    super.onDiscard();
  }
}

void main() {
  group('RouteRedirect.resolve', () {
    test(
      'throws StateError when redirect returns wrong type for resolve T',
      () async {
        final route = SpecificRedirectRoute('source', redirectToId: 'target');

        // Resolve as SpecificRedirectRoute, but redirect() returns a plain
        // BaseRoute — the new type-mismatch guard must throw instead of looping.
        await expectLater(
          () => RouteRedirect.resolve<SpecificRedirectRoute>(route, null),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('BaseRoute'),
                contains('expected SpecificRedirectRoute'),
              ),
            ),
          ),
        );
        expect(route.discarded, isTrue);
      },
    );

    test('returns redirected route when types match', () async {
      final route = SpecificRedirectRoute('source', redirectToId: 'target');

      final result = await RouteRedirect.resolve<BaseRoute>(route, null);

      expect(result, isA<BaseRoute>());
      expect(result!.id, 'target');
      expect(route.discarded, isTrue);
    });

    test('returns null and discards the route when redirect cancels', () async {
      final route = _CancelRedirectRoute('blocked');

      expect(
        await RouteRedirect.resolve<BaseRoute>(route, _UnusedCoordinator()),
        isNull,
      );
      expect(route.discarded, isTrue);
    });

    test('throws StateError on a cyclic redirect chain', () async {
      final a = _CyclicRedirectRoute('a');
      final b = _CyclicRedirectRoute('b');
      a.next = b;
      b.next = a;

      await expectLater(
        () => RouteRedirect.resolve<BaseRoute>(a, null),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('RouteRedirect loop detected'),
          ),
        ),
      );
    });
  });

  group('C20 RouteRedirect.resolve never discards a live route', () {
    test(
      'a live route stopped by a module rule keeps its result pending; a fresh one is discarded once',
      () async {
        final log = <String>[];
        final app = ScopedModularApp(
          rules: [
            RecordingRule(
              'gate',
              log,
              outcome: (_) => const RedirectResult.stop(),
            ),
          ],
        );
        final live = TrackingRoute('blocked');
        (app.root as AppStackPath).seed([live]);
        expect(live.stackPath, same(app.root));

        expect(await RouteRedirect.resolve<AppRoute>(live, app), isNull);
        expect(live.events, isEmpty);

        final fresh = TrackingRoute('blocked');
        expect(await RouteRedirect.resolve<AppRoute>(fresh, app), isNull);
        expect(fresh.events, ['onDiscard']);

        expect(log, ['gate(blocked)', 'gate(blocked)']);
        expect(app.root.stack, [same(live)]);
      },
    );

    test(
      'a live route redirected away by a module rule is not discarded; a fresh one is discarded once',
      () async {
        final log = <String>[];
        final app = ScopedModularApp(
          rules: [
            RecordingRule(
              'gate',
              log,
              outcome: (r) => r.id == 'old'
                  ? RedirectResult.redirectTo(AppRoute('new'))
                  : const RedirectResult.continueRedirect(),
            ),
          ],
        );
        final live = TrackingRoute('old');
        (app.root as AppStackPath).seed([live]);

        expect((await RouteRedirect.resolve<AppRoute>(live, app))?.id, 'new');
        expect(live.events, isEmpty);

        final fresh = TrackingRoute('old');
        expect((await RouteRedirect.resolve<AppRoute>(fresh, app))?.id, 'new');
        expect(fresh.events, ['onDiscard']);

        expect(log, ['gate(old)', 'gate(new)', 'gate(old)', 'gate(new)']);
        expect(app.root.stack, [same(live)]);
      },
    );

    test(
      'in an opted-out tree a live route whose own redirect stops or moves is not discarded',
      () async {
        final coordinator = AppCoordinator();
        final liveStop = _TrackingRedirectRoute('stop', stop: true);
        final liveMove = _TrackingRedirectRoute('move', to: AppRoute('away'));
        (coordinator.root as AppStackPath).seed([liveStop, liveMove]);

        expect(
          await RouteRedirect.resolve<AppRoute>(liveStop, coordinator),
          isNull,
        );
        expect(
          (await RouteRedirect.resolve<AppRoute>(liveMove, coordinator))?.id,
          'away',
        );
        expect(liveStop.events, isEmpty);
        expect(liveMove.events, isEmpty);

        final freshStop = _TrackingRedirectRoute('stop', stop: true);
        final freshMove = _TrackingRedirectRoute('move', to: AppRoute('away'));
        expect(
          await RouteRedirect.resolve<AppRoute>(freshStop, coordinator),
          isNull,
        );
        expect(
          (await RouteRedirect.resolve<AppRoute>(freshMove, coordinator))?.id,
          'away',
        );
        expect(freshStop.events, ['onDiscard']);
        expect(freshMove.events, ['onDiscard']);

        expect(coordinator.root.stack, [same(liveStop), same(liveMove)]);
      },
    );

    test(
      'a committed route that is navigated to again and stopped stays on screen with its result pending',
      () async {
        final log = <String>[];
        final rules = <RedirectRule>[];
        final app = ScopedModularApp(rules: rules);
        final live = TrackingRoute('page');
        await app.pushSilently(live);

        rules.add(
          RecordingRule(
            'gate',
            log,
            outcome: (_) => const RedirectResult.stop(),
          ),
        );
        await app.navigate(live);

        expect(log, ['gate(page)']);
        expect(live.events, isEmpty);
        expect(app.root.stack, [same(live)]);
      },
    );

    test(
      'an identical-instance cycle discards each route exactly once',
      () async {
        final a = _CountingCyclicRoute('a');
        final b = _CountingCyclicRoute('b');
        a.next = b;
        b.next = a;

        await expectLater(
          () => RouteRedirect.resolve<BaseRoute>(a, null),
          throwsA(isA<StateError>()),
        );
        expect(a.discards, 1);
        expect(b.discards, 1);
      },
    );
  });
}

class _UnusedCoordinator implements CoordinatorCore<RouteUri> {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CancelRedirectRoute extends BaseRoute with RouteRedirect<BaseRoute> {
  _CancelRedirectRoute(super.id);

  bool discarded = false;

  @override
  FutureOr<BaseRoute?> redirectWith(covariant CoordinatorCore coordinator) =>
      null;

  @override
  void onDiscard() {
    discarded = true;
    super.onDiscard();
  }
}

class _CyclicRedirectRoute extends BaseRoute with RouteRedirect<BaseRoute> {
  _CyclicRedirectRoute(super.id);

  late BaseRoute next;

  @override
  BaseRoute redirect() => next;
}

/// A live-trackable route whose own redirect stops or moves to [to].
class _TrackingRedirectRoute extends TrackingRoute
    with RouteRedirect<AppRoute> {
  _TrackingRedirectRoute(super.id, {this.to, this.stop = false});

  final AppRoute? to;
  final bool stop;

  @override
  FutureOr<AppRoute?> redirectWith(covariant CoordinatorCore coordinator) =>
      stop ? null : (to ?? this);
}

/// [_CyclicRedirectRoute] that counts its discards.
class _CountingCyclicRoute extends BaseRoute with RouteRedirect<BaseRoute> {
  _CountingCyclicRoute(super.id);

  late BaseRoute next;
  int discards = 0;

  @override
  BaseRoute redirect() => next;

  @override
  void onDiscard() {
    discards++;
    super.onDiscard();
  }
}
