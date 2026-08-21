import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart'
    as inapp;
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart'
    as webview;
import 'package:webview_flutter_linux/src/cookie_manager/cookie_manager.dart';
import 'package:webview_flutter_linux/src/in_app_webview/in_app_webview.dart';
import 'package:webview_flutter_linux/src/in_app_webview/in_app_webview_controller.dart';

/// Linux implementation of the `webview_flutter` federated platform API.
class LinuxWebViewPlatform extends webview.WebViewPlatform {
  /// Registers the `webview_flutter` adapter.
  static void registerWith() {
    webview.WebViewPlatform.instance = LinuxWebViewPlatform();
  }

  @override
  LinuxWebViewController createPlatformWebViewController(
    webview.PlatformWebViewControllerCreationParams params,
  ) {
    return LinuxWebViewController(params);
  }

  @override
  LinuxWebViewWidget createPlatformWebViewWidget(
    webview.PlatformWebViewWidgetCreationParams params,
  ) {
    return LinuxWebViewWidget(params);
  }

  @override
  LinuxNavigationDelegate createPlatformNavigationDelegate(
    webview.PlatformNavigationDelegateCreationParams params,
  ) {
    return LinuxNavigationDelegate(params);
  }

  @override
  LinuxWebViewCookieManager createPlatformCookieManager(
    webview.PlatformWebViewCookieManagerCreationParams params,
  ) {
    return LinuxWebViewCookieManager(params);
  }
}

/// Controller that adapts `webview_flutter` operations to WPE WebKit.
class LinuxWebViewController extends webview.PlatformWebViewController {
  final Completer<LinuxInAppWebViewController> _ready =
      Completer<LinuxInAppWebViewController>();
  final Map<String, webview.JavaScriptChannelParams> _javaScriptChannels =
      <String, webview.JavaScriptChannelParams>{};

  LinuxInAppWebViewController? _delegate;
  LinuxNavigationDelegate? _navigationDelegate;
  webview.LoadRequestParams? _pendingRequest;
  webview.JavaScriptMode _javaScriptMode = webview.JavaScriptMode.disabled;
  String? _userAgent;
  void Function(webview.PlatformWebViewPermissionRequest request)?
  _onPermissionRequest;
  void Function(webview.JavaScriptConsoleMessage message)? _onConsoleMessage;

  LinuxWebViewController(super.params) : super.implementation();

  inapp.InAppWebViewSettings get initialSettings => inapp.InAppWebViewSettings(
    javaScriptEnabled: _javaScriptMode == webview.JavaScriptMode.unrestricted,
    userAgent: _userAgent,
    useShouldOverrideUrlLoading: true,
  );

  webview.LoadRequestParams? takeInitialRequest() {
    final request = _pendingRequest;
    _pendingRequest = null;
    return request;
  }

  List<inapp.UserScript> get initialUserScripts => _javaScriptChannels.keys
      .map(_javaScriptChannelUserScript)
      .toList(growable: false);

  Future<void> attach(LinuxInAppWebViewController delegate) async {
    _delegate = delegate;

    for (final channel in _javaScriptChannels.values) {
      _registerJavaScriptHandler(delegate, channel);
    }

    await delegate.setSettings(settings: initialSettings);

    final pendingRequest = _pendingRequest;
    _pendingRequest = null;
    if (pendingRequest != null) {
      await delegate.loadUrl(urlRequest: _toInAppRequest(pendingRequest));
    }

    if (!_ready.isCompleted) {
      _ready.complete(delegate);
    }
  }

  @override
  Future<void> loadRequest(webview.LoadRequestParams params) async {
    final delegate = _delegate;
    if (delegate == null) {
      _pendingRequest = params;
      return;
    }
    await delegate.loadUrl(urlRequest: _toInAppRequest(params));
  }

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {
    final delegate = await _ready.future;
    await delegate.loadData(
      data: html,
      baseUrl: baseUrl == null ? null : inapp.WebUri(baseUrl),
    );
  }

  @override
  Future<String?> currentUrl() async {
    final delegate = _delegate;
    if (delegate == null) return _pendingRequest?.uri.toString();
    return (await delegate.getUrl())?.toString();
  }

  @override
  Future<bool> canGoBack() async => (await _ready.future).canGoBack();

  @override
  Future<bool> canGoForward() async => (await _ready.future).canGoForward();

  @override
  Future<void> goBack() async => (await _ready.future).goBack();

  @override
  Future<void> goForward() async => (await _ready.future).goForward();

  @override
  Future<void> reload() async => (await _ready.future).reload();

  @override
  Future<void> clearCache() async {
    await (await _ready.future).clearAllCache();
  }

  @override
  Future<void> clearLocalStorage() async {
    await runJavaScript('window.localStorage.clear();');
  }

  @override
  Future<void> setPlatformNavigationDelegate(
    webview.PlatformNavigationDelegate handler,
  ) async {
    if (handler is! LinuxNavigationDelegate) {
      throw ArgumentError.value(
        handler,
        'handler',
        'Expected a LinuxNavigationDelegate.',
      );
    }
    _navigationDelegate = handler;
  }

  @override
  Future<void> runJavaScript(String javaScript) async {
    await (await _ready.future).evaluateJavascript(source: javaScript);
  }

  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async {
    final result = await (await _ready.future).evaluateJavascript(
      source: javaScript,
    );
    return result ?? 'null';
  }

  @override
  Future<void> addJavaScriptChannel(
    webview.JavaScriptChannelParams javaScriptChannelParams,
  ) async {
    _javaScriptChannels[javaScriptChannelParams.name] = javaScriptChannelParams;
    final delegate = _delegate;
    if (delegate == null) return;

    _registerJavaScriptHandler(delegate, javaScriptChannelParams);
    final script = _javaScriptChannelUserScript(javaScriptChannelParams.name);
    await delegate.addUserScript(userScript: script);
    await delegate.evaluateJavascript(source: script.source);
  }

  @override
  Future<void> removeJavaScriptChannel(String javaScriptChannelName) async {
    _javaScriptChannels.remove(javaScriptChannelName);
    final delegate = _delegate;
    if (delegate == null) return;

    delegate.removeJavaScriptHandler(handlerName: javaScriptChannelName);
    await delegate.removeUserScriptsByGroupName(
      groupName: _javaScriptChannelGroup(javaScriptChannelName),
    );
    await delegate.evaluateJavascript(
      source: 'delete window[${jsonEncode(javaScriptChannelName)}];',
    );
  }

  @override
  Future<String?> getTitle() async => (await _ready.future).getTitle();

  @override
  Future<void> scrollTo(int x, int y) async {
    await (await _ready.future).scrollTo(x: x, y: y);
  }

  @override
  Future<void> scrollBy(int x, int y) async {
    await (await _ready.future).scrollBy(x: x, y: y);
  }

  @override
  Future<Offset> getScrollPosition() async {
    final delegate = await _ready.future;
    final x = await delegate.getScrollX() ?? 0;
    final y = await delegate.getScrollY() ?? 0;
    return Offset(x.toDouble(), y.toDouble());
  }

  @override
  Future<void> setJavaScriptMode(webview.JavaScriptMode javaScriptMode) async {
    _javaScriptMode = javaScriptMode;
    final delegate = _delegate;
    if (delegate != null) {
      await delegate.setSettings(settings: initialSettings);
    }
  }

  @override
  Future<void> setUserAgent(String? userAgent) async {
    _userAgent = userAgent;
    final delegate = _delegate;
    if (delegate != null) {
      await delegate.setSettings(settings: initialSettings);
    }
  }

  @override
  Future<String?> getUserAgent() async => _userAgent;

  @override
  Future<void> setOnPlatformPermissionRequest(
    void Function(webview.PlatformWebViewPermissionRequest request)
    onPermissionRequest,
  ) async {
    _onPermissionRequest = onPermissionRequest;
  }

  @override
  Future<void> setOnConsoleMessage(
    void Function(webview.JavaScriptConsoleMessage consoleMessage)
    onConsoleMessage,
  ) async {
    _onConsoleMessage = onConsoleMessage;
  }

  Future<inapp.NavigationActionPolicy?> onNavigationAction(
    inapp.NavigationAction action,
  ) async {
    final callback = _navigationDelegate?.onNavigationRequest;
    final url = action.request.url?.toString();
    if (callback == null || url == null) {
      return inapp.NavigationActionPolicy.ALLOW;
    }

    final decision = await callback(
      webview.NavigationRequest(url: url, isMainFrame: action.isForMainFrame),
    );
    return decision == webview.NavigationDecision.navigate
        ? inapp.NavigationActionPolicy.ALLOW
        : inapp.NavigationActionPolicy.CANCEL;
  }

  Future<inapp.HttpAuthResponse?> onHttpAuthRequest(
    inapp.HttpAuthenticationChallenge challenge,
  ) async {
    final callback = _navigationDelegate?.onHttpAuthRequest;
    if (callback == null) {
      return inapp.HttpAuthResponse(
        action: inapp.HttpAuthResponseAction.CANCEL,
      );
    }

    final response = Completer<inapp.HttpAuthResponse>();
    callback(
      webview.HttpAuthRequest(
        host: challenge.protectionSpace.host,
        realm: challenge.protectionSpace.realm,
        onProceed: (credential) {
          if (response.isCompleted) return;
          response.complete(
            inapp.HttpAuthResponse(
              action: inapp.HttpAuthResponseAction.PROCEED,
              username: credential.user,
              password: credential.password,
            ),
          );
        },
        onCancel: () {
          if (response.isCompleted) return;
          response.complete(
            inapp.HttpAuthResponse(action: inapp.HttpAuthResponseAction.CANCEL),
          );
        },
      ),
    );
    return response.future;
  }

  Future<inapp.PermissionResponse?> onPermissionRequest(
    inapp.PermissionRequest request,
  ) async {
    final callback = _onPermissionRequest;
    if (callback == null) {
      return inapp.PermissionResponse(
        action: inapp.PermissionResponseAction.DENY,
      );
    }

    final response = Completer<bool>();
    callback(
      LinuxWebViewPermissionRequest(
        types: _toWebViewPermissionTypes(request.resources),
        onDecision: (granted) {
          if (!response.isCompleted) response.complete(granted);
        },
      ),
    );
    final granted = await response.future;
    return inapp.PermissionResponse(
      action: granted
          ? inapp.PermissionResponseAction.GRANT
          : inapp.PermissionResponseAction.DENY,
      resources: granted ? request.resources : const [],
    );
  }

  void onPageStarted(inapp.WebUri? url) {
    if (url != null) {
      _navigationDelegate?.onPageStarted?.call(url.toString());
    }
  }

  void onPageFinished(inapp.WebUri? url) {
    if (url != null) {
      _navigationDelegate?.onPageFinished?.call(url.toString());
    }
  }

  void onUrlChange(inapp.WebUri? url) {
    _navigationDelegate?.onUrlChange?.call(
      webview.UrlChange(url: url?.toString()),
    );
  }

  void onProgress(int progress) {
    _navigationDelegate?.onProgress?.call(progress);
  }

  void onResourceError(
    inapp.WebResourceRequest request,
    inapp.WebResourceError error,
  ) {
    _navigationDelegate?.onWebResourceError?.call(
      webview.WebResourceError(
        errorCode: error.type.toValue().hashCode,
        description: error.description,
        errorType: _toWebViewErrorType(error.type),
        isForMainFrame: request.isForMainFrame,
        url: request.url.toString(),
      ),
    );
  }

  void onHttpError(
    inapp.WebResourceRequest request,
    inapp.WebResourceResponse response,
  ) {
    final statusCode = response.statusCode;
    if (statusCode == null) return;
    _navigationDelegate?.onHttpError?.call(
      webview.HttpResponseError(
        request: webview.WebResourceRequest(
          uri: Uri.parse(request.url.toString()),
        ),
        response: webview.WebResourceResponse(
          uri: Uri.tryParse(request.url.toString()),
          statusCode: statusCode,
          headers: response.headers ?? const <String, String>{},
        ),
      ),
    );
  }

  void onConsoleMessage(inapp.ConsoleMessage message) {
    final callback = _onConsoleMessage;
    if (callback == null) return;
    callback(
      webview.JavaScriptConsoleMessage(
        level: webview.JavaScriptLogLevel.log,
        message: message.message,
      ),
    );
  }

  static inapp.URLRequest _toInAppRequest(webview.LoadRequestParams params) {
    return inapp.URLRequest(
      url: inapp.WebUri(params.uri.toString()),
      method: params.method == webview.LoadRequestMethod.post ? 'POST' : 'GET',
      headers: params.headers,
      body: params.body,
    );
  }

  void _registerJavaScriptHandler(
    LinuxInAppWebViewController delegate,
    webview.JavaScriptChannelParams channel,
  ) {
    delegate.addJavaScriptHandler(
      handlerName: channel.name,
      callback: (inapp.JavaScriptHandlerFunctionData data) {
        final value = data.args.isEmpty ? '' : data.args.first.toString();
        channel.onMessageReceived(webview.JavaScriptMessage(message: value));
      },
    );
  }
}

/// Platform widget that hosts the texture-backed WPE view.
class LinuxWebViewWidget extends webview.PlatformWebViewWidget {
  LinuxWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) {
    return _LinuxWebViewHost(
      key: params.key,
      controller: params.controller as LinuxWebViewController,
      layoutDirection: params.layoutDirection,
      gestureRecognizers: params.gestureRecognizers,
    );
  }
}

class _LinuxWebViewHost extends StatefulWidget {
  final LinuxWebViewController controller;
  final TextDirection layoutDirection;
  final Set<Factory<OneSequenceGestureRecognizer>> gestureRecognizers;

  const _LinuxWebViewHost({
    super.key,
    required this.controller,
    required this.layoutDirection,
    required this.gestureRecognizers,
  });

  @override
  State<_LinuxWebViewHost> createState() => _LinuxWebViewHostState();
}

class _LinuxWebViewHostState extends State<_LinuxWebViewHost> {
  late final LinuxInAppWebViewWidget _platformView;

  @override
  void initState() {
    super.initState();
    final initialRequest = widget.controller.takeInitialRequest();
    _platformView = LinuxInAppWebViewWidget(
      LinuxInAppWebViewWidgetCreationParams(
        layoutDirection: widget.layoutDirection,
        gestureRecognizers: widget.gestureRecognizers,
        initialUrlRequest: initialRequest == null
            ? null
            : LinuxWebViewController._toInAppRequest(initialRequest),
        initialSettings: widget.controller.initialSettings,
        initialUserScripts: UnmodifiableListView<inapp.UserScript>(
          widget.controller.initialUserScripts,
        ),
        onWebViewCreated: (controller) async {
          await widget.controller.attach(
            controller as LinuxInAppWebViewController,
          );
        },
        onLoadStart: (_, url) => widget.controller.onPageStarted(url),
        onLoadStop: (_, url) => widget.controller.onPageFinished(url),
        onUpdateVisitedHistory: (_, url, _) =>
            widget.controller.onUrlChange(url),
        onProgressChanged: (_, progress) =>
            widget.controller.onProgress(progress),
        shouldOverrideUrlLoading: (_, action) =>
            widget.controller.onNavigationAction(action),
        onReceivedError: (_, request, error) =>
            widget.controller.onResourceError(request, error),
        onReceivedHttpError: (_, request, response) =>
            widget.controller.onHttpError(request, response),
        onReceivedHttpAuthRequest: (_, challenge) =>
            widget.controller.onHttpAuthRequest(challenge),
        onPermissionRequest: (_, request) =>
            widget.controller.onPermissionRequest(request),
        onConsoleMessage: (_, message) =>
            widget.controller.onConsoleMessage(message),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => _platformView.build(context);

  @override
  void dispose() {
    _platformView.dispose();
    super.dispose();
  }
}

/// Stores callbacks configured through `NavigationDelegate`.
class LinuxNavigationDelegate extends webview.PlatformNavigationDelegate {
  webview.NavigationRequestCallback? onNavigationRequest;
  webview.PageEventCallback? onPageStarted;
  webview.PageEventCallback? onPageFinished;
  webview.ProgressCallback? onProgress;
  webview.WebResourceErrorCallback? onWebResourceError;
  webview.UrlChangeCallback? onUrlChange;
  webview.HttpAuthRequestCallback? onHttpAuthRequest;
  webview.HttpResponseErrorCallback? onHttpError;

  LinuxNavigationDelegate(super.params) : super.implementation();

  @override
  Future<void> setOnNavigationRequest(
    webview.NavigationRequestCallback onNavigationRequest,
  ) async {
    this.onNavigationRequest = onNavigationRequest;
  }

  @override
  Future<void> setOnPageStarted(webview.PageEventCallback onPageStarted) async {
    this.onPageStarted = onPageStarted;
  }

  @override
  Future<void> setOnPageFinished(
    webview.PageEventCallback onPageFinished,
  ) async {
    this.onPageFinished = onPageFinished;
  }

  @override
  Future<void> setOnProgress(webview.ProgressCallback onProgress) async {
    this.onProgress = onProgress;
  }

  @override
  Future<void> setOnWebResourceError(
    webview.WebResourceErrorCallback onWebResourceError,
  ) async {
    this.onWebResourceError = onWebResourceError;
  }

  @override
  Future<void> setOnUrlChange(webview.UrlChangeCallback onUrlChange) async {
    this.onUrlChange = onUrlChange;
  }

  @override
  Future<void> setOnHttpAuthRequest(
    webview.HttpAuthRequestCallback onHttpAuthRequest,
  ) async {
    this.onHttpAuthRequest = onHttpAuthRequest;
  }

  @override
  Future<void> setOnHttpError(
    webview.HttpResponseErrorCallback onHttpError,
  ) async {
    this.onHttpError = onHttpError;
  }
}

/// Cookie manager backed by WPE WebKit's native cookie store.
class LinuxWebViewCookieManager extends webview.PlatformWebViewCookieManager {
  final LinuxCookieManager _delegate = LinuxCookieManager.static();

  LinuxWebViewCookieManager(super.params) : super.implementation();

  @override
  Future<bool> clearCookies() async {
    final hadCookies = (await _delegate.getAllCookies()).isNotEmpty;
    await _delegate.deleteAllCookies();
    return hadCookies;
  }

  @override
  Future<void> setCookie(webview.WebViewCookie cookie) async {
    final host = cookie.domain.startsWith('.')
        ? cookie.domain.substring(1)
        : cookie.domain;
    await _delegate.setCookie(
      url: inapp.WebUri('https://$host${cookie.path}'),
      name: cookie.name,
      value: cookie.value,
      domain: cookie.domain,
      path: cookie.path,
    );
  }

  @override
  Future<List<webview.WebViewCookie>> getCookies(Uri url) async {
    final cookies = await _delegate.getCookies(
      url: inapp.WebUri(url.toString()),
    );
    return cookies
        .map(
          (cookie) => webview.WebViewCookie(
            name: cookie.name,
            value: cookie.value,
            domain: cookie.domain ?? url.host,
            path: cookie.path ?? '/',
          ),
        )
        .toList(growable: false);
  }
}

class LinuxWebViewPermissionRequest
    extends webview.PlatformWebViewPermissionRequest {
  final void Function(bool granted) _onDecision;

  const LinuxWebViewPermissionRequest({
    required super.types,
    required this._onDecision,
  });

  @override
  Future<void> grant() async => _decide(true);

  @override
  Future<void> deny() async => _decide(false);

  void _decide(bool granted) {
    _onDecision(granted);
  }
}

inapp.UserScript _javaScriptChannelUserScript(String channelName) {
  final encodedName = jsonEncode(channelName);
  return inapp.UserScript(
    groupName: _javaScriptChannelGroup(channelName),
    injectionTime: inapp.UserScriptInjectionTime.AT_DOCUMENT_START,
    source:
        '''
(function() {
  const channelName = $encodedName;
  window[channelName] = {
    postMessage: function(message) {
      return window.flutter_inappwebview.callHandler(
        channelName,
        String(message)
      );
    }
  };
})();
''',
  );
}

String _javaScriptChannelGroup(String channelName) =>
    'webview_flutter_channel_$channelName';

Set<webview.WebViewPermissionResourceType> _toWebViewPermissionTypes(
  List<inapp.PermissionResourceType> resources,
) {
  final result = <webview.WebViewPermissionResourceType>{};
  for (final resource in resources) {
    if (resource == inapp.PermissionResourceType.CAMERA ||
        resource == inapp.PermissionResourceType.CAMERA_AND_MICROPHONE) {
      result.add(webview.WebViewPermissionResourceType.camera);
    }
    if (resource == inapp.PermissionResourceType.MICROPHONE ||
        resource == inapp.PermissionResourceType.CAMERA_AND_MICROPHONE) {
      result.add(webview.WebViewPermissionResourceType.microphone);
    }
  }
  return result;
}

webview.WebResourceErrorType _toWebViewErrorType(
  inapp.WebResourceErrorType type,
) {
  final name = type.name();
  if (name.contains('HOST') || name.contains('DNS')) {
    return webview.WebResourceErrorType.hostLookup;
  }
  if (name.contains('TIMEOUT') || name.contains('TIMED_OUT')) {
    return webview.WebResourceErrorType.timeout;
  }
  if (name.contains('CONNECT')) return webview.WebResourceErrorType.connect;
  if (name.contains('CANCEL')) return webview.WebResourceErrorType.unknown;
  if (name.contains('BAD_URL')) return webview.WebResourceErrorType.badUrl;
  if (name.contains('UNSUPPORTED_URL')) {
    return webview.WebResourceErrorType.unsupportedScheme;
  }
  if (name.contains('SSL') || name.contains('CERTIFICATE')) {
    return webview.WebResourceErrorType.failedSslHandshake;
  }
  if (name.contains('FILE_NOT_FOUND')) {
    return webview.WebResourceErrorType.fileNotFound;
  }
  if (name.contains('FILE')) return webview.WebResourceErrorType.file;
  return webview.WebResourceErrorType.unknown;
}
