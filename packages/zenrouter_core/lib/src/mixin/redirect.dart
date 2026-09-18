import 'dart:async';

import 'package:zenrouter_core/src/coordinator/base.dart';
import 'package:zenrouter_core/src/mixin/redirect_rule.dart';
import 'package:zenrouter_core/src/mixin/target.dart';

/// Mixin that allows routes to redirect to different destinations.
///
/// When a route with this mixin is navigated to, the coordinator calls
/// [redirectWith] (or [redirect]) to determine the final destination.
/// This enables authentication checks, permission validation, route aliases,
/// and other conditional navigation logic.
///
/// ## Role in Navigation Flow
///
/// Before any route is displayed, [resolve] runs one pass per target:
///
/// 1. The module redirect rules that gate the target run first: the root's,
///    then each enclosing module's, then the owning module's (see
///    [RouteModuleRedirectRule]). A tree where no module declares rules has
///    none, and layout parents are never offered to them.
/// 2. If every module rule continues, [redirectWith] (or [redirect]) runs.
/// 3. A `null` result cancels the navigation. `this` proceeds to this route.
///    Another route starts a new pass with that route as the target.
///
/// The chain ends when a pass leaves the target where it is. A route with no
/// redirect logic of its own and no gating module rules leaves at once.
mixin RouteRedirect<T extends RouteTarget> on RouteTarget {
  /// Maximum number of times one [resolve] may move its target before the
  /// chain is treated as a cycle. Prevents `A → B → A` from hanging
  /// navigation.
  ///
  /// Only moves are charged. A pass that leaves the target where it is (the
  /// terminal pass) costs nothing, whatever the terminal route is and whether
  /// or not module rules gate it.
  static const maxRedirectHops = 20;

  /// Resolves the final destination by following the redirect chain.
  ///
  /// This static method handles the full redirect resolution process:
  /// - Runs the gating module rules, then the route's own redirect, once per
  ///   target, until a pass leaves the target where it is or cancels
  /// - Calls [redirectWith] if coordinator is available, otherwise [redirect]
  /// - Handles route discarding for redirected-away routes, but never
  ///   discards a route that is live on a stack
  /// - Throws [StateError] if a cycle is detected, the target moves more than
  ///   [maxRedirectHops] times, a redirect returns the wrong route type, or
  ///   the redirect scope of the coordinator's tree is misconfigured
  static Future<T?> resolve<T extends RouteTarget>(
    T route,
    CoordinatorCore? coordinator,
  ) async {
    T target = route;
    final RouteModuleTree? tree;
    try {
      tree = coordinator?.moduleTreeUsingRedirectRules;
    } on StateError {
      _discard(target);
      rethrow;
    }
    final seen = <RouteTarget>{};
    var hops = 0;
    // No await before the first rule or redirectWith call: callers may read
    // a rule's effects synchronously after starting a navigation.
    while (true) {
      final List<RouteModuleRedirectRule> lineage;
      try {
        lineage = tree?.redirectLineageOf(target) ?? const [];
      } on StateError {
        _discard(target);
        rethrow;
      }
      if (target is! RouteRedirect && lineage.isEmpty) break;

      final next = await _redirectOnce(target, coordinator, tree, lineage);
      if (next == null) {
        _discard(target);
        return null;
      }
      if (next == target) break;
      if (next is! T) {
        _discard(target);
        throw StateError(
          'RouteRedirect returned ${next.runtimeType}, expected $T. '
          'Redirect destinations must be the same route type as the source.',
        );
      }
      if (!seen.add(target) || hops >= maxRedirectHops) {
        _discard(target);
        throw StateError(
          'RouteRedirect loop detected after $hops hops starting from $route',
        );
      }
      hops += 1;
      _discard(target);
      target = next;
    }
    return target;
  }

  /// Discards [route], which the chain leaves behind, unless it is live on a
  /// stack: a tab entry or a re-navigated route would have its result
  /// completed while on screen.
  static void _discard(RouteTarget route) {
    if (route.stackPath == null) route.onDiscard();
  }

  /// Runs one pass for [target]: the gating module rules in [lineage] first,
  /// then the target's own redirect when every module rule continues.
  ///
  /// Module rules receive the tree root; the route's own redirect receives
  /// the call-site [coordinator], as it always has.
  static Future<RouteTarget?> _redirectOnce(
    RouteTarget target,
    CoordinatorCore? coordinator,
    RouteModuleTree? tree,
    List<RouteModuleRedirectRule> lineage,
  ) async {
    for (final module in lineage) {
      for (final rule in module.redirectRules) {
        final result = await rule.redirectResult(tree!.root, target);
        switch (result) {
          case StopRedirect():
            return null;
          case ContinueRedirect():
            continue;
          case RedirectTo(:final route):
            return route;
        }
      }
    }
    if (target is! RouteRedirect) return target;
    final redirect = target;
    return coordinator == null
        ? await redirect.redirect()
        : await redirect.redirectWith(coordinator);
  }

  // coverage:ignore-start
  /// Returns the redirect destination for this route.
  ///
  /// Return `this` to proceed with navigation to this route.
  /// Return a different route to redirect to that route instead.
  /// Return `null` to cancel the navigation entirely.
  FutureOr<T> redirect() => this as T;
  // coverage:ignore-end

  /// Returns the redirect destination with coordinator access.
  ///
  /// This variant provides access to the coordinator for checking app state,
  /// services, or other dependencies during redirect resolution.
  ///
  /// Default implementation delegates to [redirect].
  FutureOr<T?> redirectWith(covariant CoordinatorCore coordinator) =>
      redirect();
}
