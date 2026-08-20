# webview_flutter_linux

Experimental Linux implementation of `webview_flutter`.
It adapts the texture-based WPE WebKit backend from
`flutter_inappwebview_linux` to `webview_flutter_platform_interface`.

## Source provenance

The Dart code under `lib/src/` and the native code under `linux/` are based on
`flutter_inappwebview_linux` at commit
`17527cae5a3371c1e87f9c1df4281a7710debf28`. Android and iOS code were not
copied. `webview_flutter_adapter.dart` is this package's compatibility layer.

The `flutter_inappwebview_platform_interface` dependency provides the shared
types used by that Linux code. Copying it would require rewriting its imports
and maintaining those types here.

Supported functionality:

- JavaScript execution and returning results;
- JavaScript channels compatible with `Channel.postMessage(...)`;
- navigation decisions for user, redirect, and script navigations;
- page lifecycle, URL-change, HTTP-error, and resource-error callbacks;
- HTTP Basic authentication;
- camera and microphone permission requests;
- cookie reads, writes, and clearing;
- custom user agents, history navigation, reload, and local storage.

See [WPE_BACKEND.md](WPE_BACKEND.md) for native build dependencies. This
package is experimental and is not published to pub.dev.

On Debian 13, the required WPE packages are:

```sh
sudo apt-get install libwpewebkit-2.0-dev libwpebackend-fdo-1.0-dev
```
