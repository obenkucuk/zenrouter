import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter_core/zenrouter_core.dart';

import '../support/harness.dart';

class Gate extends RedirectRule<AppRoute> {
  Gate(this.from, this.to);
  final String from;
  final AppRoute Function() to;

  @override
  FutureOr<RedirectResult<AppRoute>> redirectResult(
    CoordinatorCore coordinator,
    AppRoute route,
  ) => route.id == from
      ? RedirectResult.redirectTo(to())
      : const RedirectResult.continueRedirect();
}

/// Redirect driven by the ROUTE, the path that existed before module rules,
/// used as the reference behaviour.
class RouteGatedRoute extends AppRoute
    with RouteRedirect<AppRoute>, RouteRedirectRule<AppRoute> {
  RouteGatedRoute(super.id, this.rules, {super.parentLayoutKey});
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

/// The auth module of the reference tree: no rules of its own.
class ProbeAuth extends NestedCoordinator {
  ProbeAuth(super.parent) : super(extraLabel: 'auth');
}

/// The same auth module, declaring the rules the reference puts on the route.
class ScopedProbeAuth extends ScopedNested {
  ScopedProbeAuth(super.parent, {required super.rules})
    : super(extraLabel: 'auth');
}

Map<String, List<String>> stacksOf(CoordinatorCore coordinator) => {
  for (final path in coordinator.paths)
    path.debugLabel!: [for (final route in path.stack) (route as AppRoute).id],
};

Future<void> settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('stack contents after a redirect', () {
    test(
      'REFERENCE: route-owned rule, redirected-away route must not be in the stack',
      () async {
        final coordinator = AppCoordinator();
        final route = RouteGatedRoute('home', [
          Gate('home', () => AppRoute('login')),
        ]);

        unawaited(coordinator.push(route));
        await settle();

        expect(coordinator.root.stack.map((r) => r.id).toList(), ['login']);
      },
    );

    test('a root rule produces the SAME stack', () async {
      final coordinator = GatedCoordinator([
        Gate('home', () => AppRoute('login')),
      ]);

      unawaited(coordinator.push(AppRoute('home')));
      await settle();

      expect(coordinator.root.stack.map((r) => r.id).toList(), ['login']);
    });

    test(
      'a second push after a redirect stacks on the redirected target',
      () async {
        final coordinator = GatedCoordinator([
          Gate('home', () => AppRoute('login')),
        ]);

        unawaited(coordinator.push(AppRoute('home')));
        await settle();
        unawaited(coordinator.push(AppRoute('settings')));
        await settle();

        expect(coordinator.root.stack.map((r) => r.id).toList(), [
          'login',
          'settings',
        ]);
      },
    );

    test('a stopped navigation leaves the stack untouched', () async {
      final coordinator = GatedCoordinator([]);
      unawaited(coordinator.push(AppRoute('home')));
      await settle();

      coordinator.rules.add(_StopAll());
      unawaited(coordinator.push(AppRoute('secret')));
      await settle();

      expect(coordinator.root.stack.map((r) => r.id).toList(), ['home']);
    });
  });

  group('stack contents after a module-scoped redirect', () {
    ModularAppCoordinator reference() {
      final app = ModularAppCoordinator(modules: (c) => [ProbeAuth(c)]);
      app.registerShell(
        key: 'authShell',
        path: app.getModule<ProbeAuth>().extra,
      );
      return app;
    }

    ScopedModularApp scoped(List<RedirectRule> authRules) {
      final app = ScopedModularApp(
        rules: [],
        modules: (c) => [ScopedProbeAuth(c, rules: authRules)],
      );
      app.registerShell(
        key: 'authShell',
        path: app.getModule<ScopedProbeAuth>().extra,
      );
      return app;
    }

    test(
      'a module rule redirecting out of its stack produces the route-owned stacks',
      () async {
        final ref = reference();
        unawaited(
          ref.push(
            RouteGatedRoute('profile', [
              Gate('profile', () => AppRoute('login')),
            ], parentLayoutKey: 'authShell'),
          ),
        );
        await settle();

        final app = scoped([Gate('profile', () => AppRoute('login'))]);
        unawaited(app.push(AppRoute('profile', parentLayoutKey: 'authShell')));
        await settle();

        final expected = {
          'root': ['login'],
          'nested': <String>[],
          'auth': <String>[],
        };
        expect(stacksOf(ref), expected);
        expect(stacksOf(app), expected);
      },
    );

    test(
      'a module rule redirecting inside its stack produces the route-owned stacks',
      () async {
        final ref = reference();
        unawaited(
          ref.push(
            RouteGatedRoute('profile', [
              Gate(
                'profile',
                () => AppRoute('sign-in', parentLayoutKey: 'authShell'),
              ),
            ], parentLayoutKey: 'authShell'),
          ),
        );
        await settle();

        final app = scoped([
          Gate(
            'profile',
            () => AppRoute('sign-in', parentLayoutKey: 'authShell'),
          ),
        ]);
        unawaited(app.push(AppRoute('profile', parentLayoutKey: 'authShell')));
        await settle();

        final expected = {
          'root': ['authShell'],
          'nested': <String>[],
          'auth': ['sign-in'],
        };
        expect(stacksOf(ref), expected);
        expect(stacksOf(app), expected);
      },
    );
  });
}

class _StopAll extends RedirectRule<AppRoute> {
  @override
  FutureOr<RedirectResult<AppRoute>> redirectResult(
    CoordinatorCore coordinator,
    AppRoute route,
  ) => const RedirectResult.stop();
}
