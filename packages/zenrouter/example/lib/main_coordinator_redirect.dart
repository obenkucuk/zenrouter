// Module-scoped redirect rules: the entry point.
//
//   flutter run -t lib/main_coordinator_redirect.dart
//
// The app lives in lib/coordinator_redirect/, one file per module. Only
// app_module.dart imports modules; start reading there.

import 'package:flutter/widgets.dart';

import 'coordinator_redirect/app_module.dart';

/// Composes the tree once, for the life of the app.
void main() => runApp(CoordinatorRedirectApp(coordinator: AppCoordinator()));
