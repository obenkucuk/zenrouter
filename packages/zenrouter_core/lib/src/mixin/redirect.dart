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
///    none, and layout parents are never offered to them. A module rule that
///    redirects to the target itself moves nothing, so the next rule runs.
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
  /// - Discards every route it redirects away from, cancels, or abandons on
  ///   any error (a throwing rule or redirect included), at most once each,
  ///   when the chain ends. The error still propagates. It never discards
  ///   the route it returns, even when the chain came back to it, nor a
  ///   route that is live on a stack
  /// - Throws [StateError] if a cycle is detected, the target moves more than
  ///   [maxRedirectHops] times, a redirect returns the wrong route type, or
  ///   the redirect scope of the coordinator's tree is misconfigured
  static Future<T?> resolve<T extends RouteTarget>(
    T route,
    CoordinatorCore? coordinator,
  ) async {
    T target = route;
    // The targets the chain moved away from, in order: adding one again is a
    // cycle, and their count is the hop count. A chain may come back to one
    // of them (gated → splash → gated), so they are discarded only once the
    // chain ends, and never the route it returns.
    final movedFrom = <RouteTarget>{};
    RouteTarget? returned;
    Set<RouteTarget>? discarded;
    void discard(RouteTarget abandoned) {
      // Never a live stack member: a tab entry, or a re-navigated or restored
      // route, would have its result completed while on screen. At most once
      // each: a cycle names a route twice.
      if (abandoned.stackPath != null) return;
      if ((discarded ??= Set.identity()).add(abandoned)) abandoned.onDiscard();
    }

    try {
      final tree = coordinator?.moduleTreeUsingRedirectRules;
      // No await before the first rule or redirectWith call: callers may read
      // a rule's effects synchronously after starting a navigation.
      while (true) {
        final lineage =
            tree?.redirectLineageOf(target) ??
            const <RouteModuleRedirectRule>[];
        if (target is! RouteRedirect && lineage.isEmpty) break;

        final next = await _redirectOnce(
          target,
          coordinator,
          tree?.root,
          lineage,
          discard,
        );
        if (next == null) return null;
        if (next == target) {
          // An equal new instance ends the chain on the current target. It
          // is never shown, so it is discarded.
          if (!identical(next, target)) discard(next);
          break;
        }
        if (next is! T) {
          discard(next);
          throw StateError(
            'RouteRedirect returned ${next.runtimeType}, expected $T. '
            'Redirect destinations must be the same route type as the source.',
          );
        }
        if (movedFrom.length >= maxRedirectHops || !movedFrom.add(target)) {
          discard(next);
          throw StateError(
            'RouteRedirect loop detected after ${movedFrom.length} hops '
            'starting from $route',
          );
        }
        target = next;
      }
      returned = target;
      return target;
    } finally {
      // However the chain ended (a result, a cancel, or an error from a
      // rule, a redirect or the scope lookup), discard what it abandoned.
      for (final abandoned in movedFrom) {
        if (!identical(abandoned, returned)) discard(abandoned);
      }
      if (!identical(target, returned)) discard(target);
    }
  }

  /// Runs one pass for [target]: the gating module rules in [lineage] first,
  /// then the target's own redirect when every module rule continues.
  ///
  /// Module rules receive the tree [root]; the route's own redirect receives
  /// the call-site [coordinator], as it always has.
  ///
  /// A module rule that redirects to [target] itself moves nothing, so it
  /// does not end the pass: a gate must not be skipped because a rule above
  /// it handed the destination back. The rules below it still run, and an
  /// equal new instance, which is never shown, goes to [discard].
  static Future<RouteTarget?> _redirectOnce(
    RouteTarget target,
    CoordinatorCore? coordinator,
    CoordinatorCore? root,
    List<RouteModuleRedirectRule> lineage,
    void Function(RouteTarget abandoned) discard,
  ) async {
    for (final module in lineage) {
      for (final rule in module.redirectRules) {
        switch (await rule.redirectResult(root!, target)) {
          case StopRedirect():
            return null;
          case ContinueRedirect():
            continue;
          case RedirectTo(:final route):
            if (route != target) return route;
            if (!identical(route, target)) discard(route);
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
