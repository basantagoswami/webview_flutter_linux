# Upstream

This experimental Linux plugin is based on `flutter_inappwebview_linux` at commit
`17527cae5a3371c1e87f9c1df4281a7710debf28`.

The upstream project is licensed under the Apache License 2.0. Its native WPE backend and Dart implementation form the foundation of this package's `webview_flutter` compatibility layer. See `LICENSE`.

Local changes:

- expose the backend through `webview_flutter_platform_interface`;
- keep registration Linux-only;
- expose cookie reads through `webview_flutter_platform_interface`;
- vendor the pinned nlohmann/json header so builds do not fetch source code;
- remove the upstream example application from this vendored experiment.
