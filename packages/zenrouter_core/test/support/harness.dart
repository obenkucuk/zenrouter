// ignore_for_file: invalid_use_of_protected_member
// ignore_for_file: invalid_use_of_visible_for_testing_member
// ignore_for_file: deprecated_member_use_from_same_package

import 'dart:async';

import 'package:zenrouter_core/src/internal/reactive.dart';
import 'package:zenrouter_core/src/path/commit.dart';
import 'package:zenrouter_core/zenrouter_core.dart';

/// Listener bookkeeping used by headless [ListenableObject] implementations.
mixin RecordingListenable {
  final List<VoidCallback> listeners = [];

  void addListener(VoidCallback listener) => listeners.add(listener);

  void removeListener(VoidCallback listener) => listeners.remove(listener);

  void notifyListeners() {
    for (final listener in List<VoidCallback>.of(listeners)) {
      listener();
    }
  }
}

class AppRoute extends RouteUri {
  AppRoute(this.id, {this.parentLayoutKey});

  final String id;

  @override
  final Object? parentLayoutKey;

  @override
  Uri toUri() => Uri.parse('/$id');

  @override
  List<Object?> get props => [id];

  @override
  String toString() => 'AppRoute($id)';
}

class TrackingRoute extends AppRoute {
  TrackingRoute(super.id, {super.parentLayoutKey});

  final events = <String>[];

  @override
  void onDidPop(Object? result, covariant CoordinatorCore? coordinator) {
    events.add('onDidPop');
    super.onDidPop(result, coordinator);
  }

  @override
  void onDiscard() {
    events.add('onDiscard');
    super.onDiscard();
  }

  @override
  void onUpdate(covariant RouteTarget newRoute) {
    events.add('onUpdate:${(newRoute as AppRoute).id}');
    super.onUpdate(newRoute);
  }
}

class GuardedAppRoute extends AppRoute with RouteGuard {
  GuardedAppRoute(super.id, {this.allowPop = true, super.parentLayoutKey});

  final bool allowPop;

  @override
  FutureOr<bool> popGuard() => allowPop;
}

class RedirectAppRoute extends AppRoute with RouteRedirect<AppRoute> {
  RedirectAppRoute(super.id, {this.to, this.stop = false});

  final AppRoute? to;
  final bool stop;
  int redirectCalls = 0;

  @override
  FutureOr<AppRoute> redirect() {
    redirectCalls++;
    return to ?? this;
  }

  @override
  FutureOr<AppRoute?> redirectWith(covariant CoordinatorCore coordinator) {
    redirectCalls++;
    if (stop) return null;
    return to ?? this;
  }
}

class DeepLinkAppRoute extends AppRoute with RouteDeepLink {
  DeepLinkAppRoute(super.id, {required this.deeplinkStrategy});

  @override
  final DeeplinkStrategy deeplinkStrategy;

  var customHandlerCalled = false;

  @override
  FutureOr<void> deeplinkHandler(
    covariant CoordinatorCore coordinator,
    Uri uri,
  ) {
    customHandlerCalled = true;
  }
}

class AppLayout extends AppRoute with RouteLayoutParent<AppRoute> {
  AppLayout(
    super.id, {
    required this.layoutKey,
    required this.path,
    super.parentLayoutKey,
  });

  @override
  final Object layoutKey;

  final StackPath path;

  @override
  StackPath resolvePath(covariant CoordinatorCore coordinator) => path;
}

class AppStackPath extends StackPath<AppRoute>
    with RecordingListenable, StackMutatable<AppRoute> {
  AppStackPath({super.coordinator, super.debugLabel}) : super([]);

  @override
  AppRoute? get activeRoute => stack.lastOrNull;

  @override
  PathKey get pathKey => const PathKey('app');

  @override
  void reset() {
    clear();
    notifyListeners();
  }

  @override
  Future<void> activateRoute(AppRoute route) => pushSilently(route);

  void seed(Iterable<AppRoute> routes) => bindStack(List.of(routes));
}

/// [StackPath] that is neither [StackCommit] nor [StackNavigatable].
class ActivateOnlyPath extends StackPath<AppRoute> with RecordingListenable {
  ActivateOnlyPath({super.coordinator, super.debugLabel}) : super([]);

  var activateCalls = 0;

  @override
  AppRoute? get activeRoute => stack.lastOrNull;

  @override
  PathKey get pathKey => const PathKey('activate-only');

  @override
  void reset() {
    clear();
    notifyListeners();
  }

  @override
  Future<void> activateRoute(AppRoute route) async {
    activateCalls++;
    bindStack([...stack, route]);
    notifyListeners();
  }
}

/// [StackNavigatable] path that is not a [StackCommit].
class NavigateOnlyPath extends StackPath<AppRoute>
    with RecordingListenable, StackNavigatable<AppRoute> {
  NavigateOnlyPath({super.coordinator, super.debugLabel}) : super([]);

  var navigateCalls = 0;

  @override
  AppRoute? get activeRoute => stack.lastOrNull;

  @override
  PathKey get pathKey => const PathKey('navigate-only');

  @override
  void reset() {
    clear();
    notifyListeners();
  }

  @override
  Future<void> activateRoute(AppRoute route) async {
    bindStack([...stack, route]);
    notifyListeners();
  }

  @override
  Future<void> navigate(AppRoute route) async {
    navigateCalls++;
    await activateRoute(route);
  }
}

class AppCoordinator extends CoordinatorCore<AppRoute>
    with
        RecordingListenable,
        CoordinatorLayoutCore<AppRoute>,
        CoordinatorNavigatable<AppRoute>,
        CoordinatorMutatable<AppRoute>,
        CoordinatorRecoverable<AppRoute> {
  AppCoordinator({
    super.initialRoutePath,
    this.parser,
    AppStackPath? root,
    this.extraPaths = const [],
  }) : _providedRoot = root;

  final FutureOr<AppRoute?> Function(Uri uri)? parser;
  final AppStackPath? _providedRoot;
  final List<StackPath> extraPaths;

  late final AppStackPath nested = AppStackPath(
    coordinator: this,
    debugLabel: 'nested',
  );

  late final AppStackPath _root =
      _providedRoot ?? AppStackPath(coordinator: this, debugLabel: 'root');

  @override
  StackPath<AppRoute> get root => _root;

  @override
  List<StackPath> get paths => [...super.paths, nested, ...extraPaths];

  @override
  FutureOr<AppRoute?> parseRouteFromUri(Uri uri) {
    if (parser != null) return parser!(uri);
    final id = uri.pathSegments.isEmpty ? 'home' : uri.pathSegments.join('/');
    return AppRoute(id);
  }

  void registerShell({Object key = 'shell', StackPath? path}) {
    defineLayoutParentConstructor(
      key,
      (layoutKey) => AppLayout(
        layoutKey.toString(),
        layoutKey: layoutKey,
        path: path ?? nested,
      ),
    );
  }
}

class ModularAppCoordinator extends AppCoordinator
    with CoordinatorModular<AppRoute> {
  ModularAppCoordinator({
    Iterable<RouteModule<AppRoute>> Function(ModularAppCoordinator coordinator)?
    modules,
    this.localFragment,
    this.manifestName,
  }) : _modulesBuilder = modules;

  final Iterable<RouteModule<AppRoute>> Function(ModularAppCoordinator)?
  _modulesBuilder;
  final RouteManifestFragment<Object>? localFragment;
  final String? manifestName;

  @override
  String get routeManifestName => manifestName ?? super.routeManifestName;

  @override
  RouteManifestFragment<Object> get localRouteManifestFragment =>
      localFragment ?? super.localRouteManifestFragment;

  @override
  Iterable<RouteModule<AppRoute>> defineModules() =>
      _modulesBuilder?.call(this) ?? const [];

  @override
  AppRoute notFoundRoute(Uri uri) => AppRoute('not-found');
}

class NestedCoordinator extends CoordinatorCore<AppRoute>
    with
        RecordingListenable,
        CoordinatorLayoutCore<AppRoute>,
        CoordinatorNavigatable<AppRoute>,
        CoordinatorMutatable<AppRoute>,
        CoordinatorRecoverable<AppRoute>,
        CoordinatorModular<AppRoute> {
  NestedCoordinator(
    this._parent, {
    this.childModules = const [],
    this.extraLabel = 'nested-extra',
    this.childModulesBuilder,
  });

  final CoordinatorModular<AppRoute> _parent;
  final Iterable<RouteModule<AppRoute>> childModules;

  /// Debug label of [extra].
  final String extraLabel;

  /// Builds the child modules with this coordinator as their parent, so
  /// module coordinators two levels deep can be composed. Preferred over
  /// [childModules] when set.
  final Iterable<RouteModule<AppRoute>> Function(NestedCoordinator self)?
  childModulesBuilder;

  late final AppStackPath extra = AppStackPath(
    coordinator: this,
    debugLabel: extraLabel,
  );

  @override
  CoordinatorModular<AppRoute> get coordinator => _parent;

  @override
  StackPath<AppRoute> get root => _parent.root;

  @override
  List<StackPath> get paths => [...super.paths, extra];

  @override
  Iterable<RouteModule<AppRoute>> defineModules() =>
      childModulesBuilder?.call(this) ?? childModules;

  @override
  AppRoute notFoundRoute(Uri uri) => AppRoute('nested-not-found');

  @override
  FutureOr<AppRoute?> parseRouteFromUri(Uri uri) =>
      super.parseRouteFromUri(uri);
}

class FeatureModule extends RouteModule<AppRoute> {
  FeatureModule(
    super.coordinator, {
    this.prefix = 'feature',
    this.fragment,
    this.hasPath = false,
  });

  final String prefix;
  final RouteManifestFragment<Object>? fragment;
  final bool hasPath;

  int layoutCalls = 0;
  int converterCalls = 0;

  late final AppStackPath featurePath = AppStackPath(
    coordinator: coordinator,
    debugLabel: prefix,
  );

  @override
  List<StackPath> get paths => hasPath ? [featurePath] : super.paths;

  @override
  RouteManifest<Object> get routeManifest => fragment == null
      ? super.routeManifest
      : RouteManifest(
          name: fragment!.name,
          routes: fragment!.routes,
          layouts: fragment!.layouts,
          idCodec: fragment!.idCodec,
        );

  @override
  RouteManifestFragment<Object> get routeManifestFragment =>
      fragment ?? super.routeManifestFragment;

  @override
  void defineLayout() {
    layoutCalls++;
    super.defineLayout();
  }

  @override
  void defineConverter() {
    converterCalls++;
    super.defineConverter();
  }

  @override
  FutureOr<AppRoute?> parseRouteFromUri(Uri uri) {
    if (uri.pathSegments case [final first, ...] when first == prefix) {
      return AppRoute(uri.pathSegments.join('/'));
    }
    return null;
  }
}

class AsyncFeatureModule extends FeatureModule {
  AsyncFeatureModule(super.coordinator, {super.prefix, this.delay});

  final Duration? delay;

  @override
  Future<AppRoute?> parseRouteFromUri(Uri uri) async {
    if (delay != null) await Future<void>.delayed(delay!);
    return super.parseRouteFromUri(uri);
  }
}

// ---------------------------------------------------------------------------
// Module-scoped redirect rules (RouteModuleRedirectRule)
// ---------------------------------------------------------------------------

/// Logs `'$name(${route.id})'` for every route it is offered, records the
/// coordinator it received, then returns [outcome] (continue by default).
class RecordingRule extends RedirectRule<AppRoute> {
  RecordingRule(this.name, this.log, {this.outcome});

  final String name;
  final List<String> log;

  /// Decides the result per route. Mutable so a test can change a verdict
  /// between navigations.
  RedirectResult<AppRoute> Function(AppRoute route)? outcome;

  /// Every coordinator this rule received, in call order.
  final coordinators = <CoordinatorCore>[];

  @override
  FutureOr<RedirectResult<AppRoute>> redirectResult(
    CoordinatorCore coordinator,
    AppRoute route,
  ) {
    log.add('$name(${route.id})');
    coordinators.add(coordinator);
    return outcome?.call(route) ?? const RedirectResult.continueRedirect();
  }
}

/// A modular root coordinator that declares module-scoped redirect rules.
class ScopedModularApp extends ModularAppCoordinator
    with RouteModuleRedirectRule<AppRoute> {
  ScopedModularApp({required this.rules, super.modules});

  /// Backs [redirectRules]; mutate it to change the rules live.
  final List<RedirectRule> rules;

  @override
  List<RedirectRule> get redirectRules => rules;
}

/// A module coordinator that declares module-scoped redirect rules.
class ScopedNested extends NestedCoordinator
    with RouteModuleRedirectRule<AppRoute> {
  ScopedNested(
    super.parent, {
    required this.rules,
    super.childModules,
    super.extraLabel,
    super.childModulesBuilder,
  });

  /// Backs [redirectRules]; mutate it to change the rules live.
  final List<RedirectRule> rules;

  @override
  List<RedirectRule> get redirectRules => rules;
}

/// A plain route module that declares module-scoped redirect rules.
class ScopedFeature extends FeatureModule
    with RouteModuleRedirectRule<AppRoute> {
  ScopedFeature(
    super.coordinator, {
    required this.rules,
    super.prefix,
    super.hasPath,
  });

  /// Backs [redirectRules]; mutate it to change the rules live.
  final List<RedirectRule> rules;

  @override
  List<RedirectRule> get redirectRules => rules;
}

/// A shell [AppLayout] that reports every `onDiscard` to [onDiscarded].
class CountingLayout extends AppLayout {
  CountingLayout(
    super.id, {
    required super.layoutKey,
    required super.path,
    required this.onDiscarded,
  });

  final void Function(CountingLayout layout) onDiscarded;
  int discards = 0;

  @override
  void onDiscard() {
    discards++;
    onDiscarded(this);
    super.onDiscard();
  }
}

/// Registers the shell constructor for [key] on a coordinator, like
/// [AppCoordinator.registerShell], and counts how many [CountingLayout]s it
/// builds and how many of them are discarded.
class CountingShellConstructor {
  CountingShellConstructor(
    CoordinatorCore coordinator, {
    required this.key,
    required StackPath path,
  }) {
    coordinator.defineLayoutParentConstructor(key, (layoutKey) {
      final layout = CountingLayout(
        layoutKey.toString(),
        layoutKey: layoutKey,
        path: path,
        onDiscarded: (_) => discards++,
      );
      built.add(layout);
      return layout;
    });
  }

  final Object key;

  /// Every layout the constructor built, in order.
  final built = <CountingLayout>[];

  /// Total `onDiscard` calls across [built].
  int discards = 0;

  int get constructions => built.length;
}

/// A coordinator that declares module-scoped redirect rules and works either
/// standalone (no [parent], so `isRouteModule` is false) or registered as a
/// module of [parent]: one class in two roles.
class DualRoleCoordinator extends CoordinatorCore<AppRoute>
    with
        RecordingListenable,
        CoordinatorLayoutCore<AppRoute>,
        CoordinatorNavigatable<AppRoute>,
        CoordinatorMutatable<AppRoute>,
        CoordinatorRecoverable<AppRoute>,
        RouteModuleRedirectRule<AppRoute> {
  DualRoleCoordinator({this.parent, required this.rules, this.label = 'dual'});

  final CoordinatorModular<AppRoute>? parent;
  final List<RedirectRule> rules;
  final String label;

  late final AppStackPath _ownRoot = AppStackPath(
    coordinator: this,
    debugLabel: '$label-root',
  );

  /// The stack this coordinator owns in either role.
  late final AppStackPath stack = AppStackPath(
    coordinator: this,
    debugLabel: label,
  );

  @override
  CoordinatorModular<AppRoute> get coordinator => parent ?? super.coordinator;

  @override
  StackPath<AppRoute> get root => parent?.root ?? _ownRoot;

  @override
  List<StackPath> get paths => [...super.paths, stack];

  @override
  List<RedirectRule> get redirectRules => rules;

  @override
  FutureOr<AppRoute?> parseRouteFromUri(Uri uri) {
    if (isRouteModule) return null;
    return AppRoute(
      uri.pathSegments.isEmpty ? 'home' : uri.pathSegments.join('/'),
    );
  }
}
