import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter_core/zenrouter_core.dart';

import '../support/harness.dart';

/// Plain destination: carries no redirect logic of its own.
class PlainRoute extends AppRoute {
  PlainRoute(super.id, {super.parentLayoutKey});
}

/// Destination with its own rule chain, used to pin ordering against the
/// module rules.
class RuledRoute extends AppRoute
    with RouteRedirect<AppRoute>, RouteRedirectRule<AppRoute> {
  RuledRoute(super.id, this.rules, {super.parentLayoutKey});

  final List<RedirectRule> rules;

  @override
  List<RedirectRule> get redirectRules => rules;
}

/// A standalone root that declares redirect rules. It lists its root stack,
/// so its rules gate every destination.
class GatedCoordinator extends AppCoordinator
    with RouteModuleRedirectRule<AppRoute> {
  GatedCoordinator(this.rules);

  final List<RedirectRule> rules;

  @override
  List<RedirectRule> get redirectRules => rules;
}

/// A module coordinator that does NOT mix the rules in.
class PlainNestedCoordinator extends NestedCoordinator {
  PlainNestedCoordinator(super.parent) : super(extraLabel: 'plain-nested');
}

/// A module coordinator that declares rules of its own.
class RuledNestedCoordinator extends ScopedNested {
  RuledNestedCoordinator(super.parent, {required super.rules})
    : super(extraLabel: 'ruled-nested');
}

/// Walks `hop-0 → hop-1 → … → hop-(limit-1) → done`, i.e. exactly [limit]
/// redirects.
class HopRule extends RedirectRule<AppRoute> {
  HopRule(this.limit);
  final int limit;

  @override
  RedirectResult<AppRoute> redirectResult(
    CoordinatorCore coordinator,
    AppRoute route,
  ) {
    final id = route.id;
    if (!id.startsWith('hop-')) return const RedirectResult.continueRedirect();
    final n = int.parse(id.substring(4));
    return RedirectResult.redirectTo(
      PlainRoute(n + 1 >= limit ? 'done' : 'hop-${n + 1}'),
    );
  }
}

class AsyncRule extends RedirectRule<AppRoute> {
  AsyncRule(this.log, this.outcome);
  final List<String> log;
  final RedirectResult<AppRoute> Function() outcome;

  @override
  Future<RedirectResult<AppRoute>> redirectResult(
    CoordinatorCore coordinator,
    AppRoute route,
  ) async {
    await Future<void>.delayed(Duration.zero);
    log.add('async(${route.id})');
    return outcome();
  }
}

class DiscardCountingRoute extends AppRoute {
  DiscardCountingRoute(super.id, {super.parentLayoutKey});
  int discards = 0;

  @override
  void onDiscard() {
    discards += 1;
    super.onDiscard();
  }
}

class SpecificRoute extends AppRoute with RouteRedirect<SpecificRoute> {
  SpecificRoute(super.id);
  int discards = 0;

  @override
  void onDiscard() {
    discards += 1;
    super.onDiscard();
  }
}

Future<void> settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('RouteModuleRedirectRule on the root', () {
    test(
      'applies the root rules to a route with no rules of its own',
      () async {
        final log = <String>[];
        final coordinator = GatedCoordinator([RecordingRule('gate', log)]);

        final resolved = await RouteRedirect.resolve(
          PlainRoute('home'),
          coordinator,
        );

        expect(
          log,
          ['gate(home)'],
          reason:
              'App-wide gates must reach destinations that carry no redirect '
              'logic, which is the whole point of root rules',
        );
        expect(resolved, isA<PlainRoute>().having((r) => r.id, 'id', 'home'));
      },
    );

    test('StopRedirect from a root rule cancels navigation', () async {
      final log = <String>[];
      final coordinator = GatedCoordinator([
        RecordingRule('gate', log, outcome: (_) => const RedirectResult.stop()),
      ]);
      final route = DiscardCountingRoute('secret');

      final resolved = await RouteRedirect.resolve(route, coordinator);

      expect(resolved, isNull);
      expect(log, ['gate(secret)']);
      expect(route.discards, 1);
    });

    test('RedirectTo from a root rule sends the user elsewhere', () async {
      final log = <String>[];
      final coordinator = GatedCoordinator([
        RecordingRule(
          'gate',
          log,
          outcome: (route) => route.id == 'home'
              ? RedirectResult.redirectTo(PlainRoute('login'))
              : const RedirectResult.continueRedirect(),
        ),
      ]);

      final resolved = await RouteRedirect.resolve(
        PlainRoute('home'),
        coordinator,
      );

      expect(resolved, isA<PlainRoute>().having((r) => r.id, 'id', 'login'));
      expect(
        log,
        ['gate(home)', 'gate(login)'],
        reason:
            'The destination reached by a redirect must be gated too, '
            'otherwise a rule could hand out an ungated route',
      );
    });

    test('root rules run BEFORE the route own rules', () async {
      final log = <String>[];
      final coordinator = GatedCoordinator([RecordingRule('root', log)]);
      final route = RuledRoute('home', [RecordingRule('route', log)]);

      await RouteRedirect.resolve(route, coordinator);

      expect(log, ['root(home)', 'route(home)']);
    });

    test('a stopping root rule short-circuits the route own rules', () async {
      final log = <String>[];
      final coordinator = GatedCoordinator([
        RecordingRule('root', log, outcome: (_) => const RedirectResult.stop()),
      ]);
      final route = RuledRoute('home', [RecordingRule('route', log)]);

      final resolved = await RouteRedirect.resolve(route, coordinator);

      expect(resolved, isNull);
      expect(log, ['root(home)']);
    });

    test('a coordinator without the mixin behaves exactly as before', () async {
      final log = <String>[];
      final coordinator = AppCoordinator();
      final route = RuledRoute('home', [RecordingRule('route', log)]);

      final resolved = await RouteRedirect.resolve(route, coordinator);

      expect(resolved, same(route));
      expect(log, ['route(home)']);
      expect(coordinator.redirectScopeOf(route), isEmpty);
    });

    test(
      'several rules run in order and the first non-continue wins',
      () async {
        final log = <String>[];
        final coordinator = GatedCoordinator([
          RecordingRule('first', log),
          RecordingRule(
            'second',
            log,
            outcome: (_) => const RedirectResult.stop(),
          ),
          RecordingRule('third', log),
        ]);

        final resolved = await RouteRedirect.resolve(
          PlainRoute('home'),
          coordinator,
        );

        expect(resolved, isNull);
        expect(log, ['first(home)', 'second(home)']);
      },
    );

    test('an asynchronous rule is awaited', () async {
      final log = <String>[];
      final coordinator = GatedCoordinator([
        AsyncRule(log, () => const RedirectResult.stop()),
      ]);

      final resolved = await RouteRedirect.resolve(
        PlainRoute('home'),
        coordinator,
      );

      expect(resolved, isNull);
      expect(log, ['async(home)']);
    });

    test(
      'a root rule redirecting to the wrong route type throws and discards the source',
      () async {
        final other = DiscardCountingRoute('other');
        final coordinator = GatedCoordinator([
          RecordingRule(
            'bad',
            <String>[],
            outcome: (_) => RedirectResult.redirectTo(other),
          ),
        ]);
        final source = SpecificRoute('home');

        await expectLater(
          () => RouteRedirect.resolve<SpecificRoute>(source, coordinator),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('expected SpecificRoute'),
            ),
          ),
        );
        expect(source.discards, 1);
      },
    );

    test('layout parents are NOT gated', () async {
      final log = <String>[];
      final coordinator = GatedCoordinator([RecordingRule('gate', log)]);

      final shell = AppLayout(
        'shell',
        layoutKey: 'shell',
        path: coordinator.nested,
      );
      await RouteRedirect.resolve(shell, coordinator);

      expect(
        log,
        isEmpty,
        reason:
            'mounting a destination also resolves its shell; stopping one '
            'there would empty the root stack and strand the destination',
      );
      expect(coordinator.redirectScopeOf(shell), isEmpty);
    });

    test(
      'a pass-through route is returned untouched and never discarded',
      () async {
        final coordinator = GatedCoordinator([
          RecordingRule('gate', <String>[]),
        ]);
        final route = DiscardCountingRoute('home');

        final resolved = await RouteRedirect.resolve(route, coordinator);

        expect(resolved, same(route));
        expect(route.discards, 0);
      },
    );

    test('a redirected-away route is discarded exactly once', () async {
      final from = DiscardCountingRoute('home');
      final coordinator = GatedCoordinator([
        RecordingRule(
          'gate',
          <String>[],
          outcome: (r) => r.id == 'home'
              ? RedirectResult.redirectTo(PlainRoute('login'))
              : const RedirectResult.continueRedirect(),
        ),
      ]);

      await RouteRedirect.resolve<AppRoute>(from, coordinator);

      expect(from.discards, 1);
    });

    test('the hop budget counts moves: 20 resolve, 21 throw', () async {
      // Both ends are pinned so the terminal pass, which moves nothing, can
      // never quietly start charging budget.
      final coordinator = GatedCoordinator([
        HopRule(RouteRedirect.maxRedirectHops),
      ]);

      final resolved = await RouteRedirect.resolve(
        PlainRoute('hop-0'),
        coordinator,
      );
      expect(resolved, isA<PlainRoute>().having((r) => r.id, 'id', 'done'));

      final tooLong = GatedCoordinator([
        HopRule(RouteRedirect.maxRedirectHops + 1),
      ]);
      await expectLater(
        () => RouteRedirect.resolve(PlainRoute('hop-0'), tooLong),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('RouteRedirect loop detected after 20 hops'),
          ),
        ),
      );
    });

    test('a redirect cycle created by root rules is still caught', () async {
      final log = <String>[];
      final coordinator = GatedCoordinator([
        RecordingRule(
          'pingpong',
          log,
          outcome: (route) => RedirectResult.redirectTo(
            PlainRoute(route.id == 'a' ? 'b' : 'a'),
          ),
        ),
      ]);

      await expectLater(
        () => RouteRedirect.resolve(PlainRoute('a'), coordinator),
        throwsA(isA<StateError>()),
      );
      expect(log, ['pingpong(a)', 'pingpong(b)', 'pingpong(a)']);
    });
  });

  group('module coordinators', () {
    test(
      'a module coordinator without the mixin still gets root rules',
      () async {
        // The fork pinned the opposite: a module coordinator without the mixin
        // resolved with no rules at all, which bypassed every root gate.
        final log = <String>[];
        late PlainNestedCoordinator nested;
        final host = ScopedModularApp(
          rules: [RecordingRule('host', log)],
          modules: (c) => [nested = PlainNestedCoordinator(c)],
        );
        host.registerShell(key: 'plainShell', path: nested.extra);

        final resolved = await RouteRedirect.resolve(
          PlainRoute('home'),
          nested,
        );
        expect(resolved, isA<PlainRoute>());
        expect(log, ['host(home)']);

        log.clear();
        await nested.pushSilently(
          PlainRoute('inside', parentLayoutKey: 'plainShell'),
        );
        expect(log, [
          'host(inside)',
        ], reason: 'the module declares nothing and contributes nothing');
        expect(nested.extra.stack.map((r) => r.id), ['inside']);
        expect(host.root.stack.map((r) => r.id), ['plainShell']);
        expect(host.redirectScopeOf(PlainRoute('home')), [same(host)]);
        expect(nested.redirectScopeOf(PlainRoute('home')), [same(host)]);
      },
    );

    test('module rules add to root rules and never replace them', () async {
      final log = <String>[];
      late RuledNestedCoordinator module;
      final host = ScopedModularApp(
        rules: [RecordingRule('host', log)],
        modules: (c) => [
          module = RuledNestedCoordinator(
            c,
            rules: [RecordingRule('own', log)],
          ),
        ],
      );
      host.registerShell(key: 'ruledShell', path: module.extra);

      await module.pushSilently(
        PlainRoute('inside', parentLayoutKey: 'ruledShell'),
      );
      expect(log, ['host(inside)', 'own(inside)']);

      log.clear();
      await host.pushSilently(
        PlainRoute('again', parentLayoutKey: 'ruledShell'),
      );
      expect(log, ['host(again)', 'own(again)']);

      log.clear();
      await module.pushSilently(PlainRoute('home'));
      expect(
        log,
        ['host(home)'],
        reason:
            'a layout-less route lands on the root stack, which the module '
            'does not own, whatever the call site',
      );

      expect(module.extra.stack.map((r) => r.id), ['inside', 'again']);
      expect(host.root.stack.map((r) => r.id), ['ruledShell', 'home']);
    });

    test('a root Stop leaves the module rule uninvoked', () async {
      final log = <String>[];
      late RuledNestedCoordinator module;
      final host = ScopedModularApp(
        rules: [
          RecordingRule(
            'host',
            log,
            outcome: (_) => const RedirectResult.stop(),
          ),
        ],
        modules: (c) => [
          module = RuledNestedCoordinator(
            c,
            rules: [RecordingRule('own', log)],
          ),
        ],
      );
      host.registerShell(key: 'ruledShell', path: module.extra);
      final route = DiscardCountingRoute(
        'inside',
        parentLayoutKey: 'ruledShell',
      );

      final resolved = await RouteRedirect.resolve(route, module);

      expect(resolved, isNull);
      expect(log, ['host(inside)']);
      expect(route.discards, 1);
      await settle();
      expect(module.extra.stack, isEmpty);
      expect(host.root.stack, isEmpty);
    });
  });
}
