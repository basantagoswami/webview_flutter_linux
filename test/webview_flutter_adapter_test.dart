import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart'
    as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter_linux/webview_flutter_adapter.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart'
    as webview;

void main() {
  late LinuxWebViewController controller;
  late LinuxNavigationDelegate navigationDelegate;

  setUp(() {
    final platform = LinuxWebViewPlatform();
    webview.WebViewPlatform.instance = platform;
    controller = platform.createPlatformWebViewController(
      const webview.PlatformWebViewControllerCreationParams(),
    );
    navigationDelegate = platform.createPlatformNavigationDelegate(
      const webview.PlatformNavigationDelegateCreationParams(),
    );
  });

  test(
    'retains settings and the initial request until the widget is built',
    () async {
      final uri = Uri.parse('https://accounts.example.com/login');

      await controller.setJavaScriptMode(webview.JavaScriptMode.unrestricted);
      await controller.setUserAgent('Example Linux App');
      await controller.loadRequest(webview.LoadRequestParams(uri: uri));

      expect(controller.initialSettings.javaScriptEnabled, isTrue);
      expect(controller.initialSettings.userAgent, 'Example Linux App');
      expect(await controller.currentUrl(), uri.toString());
      expect(controller.takeInitialRequest()?.uri, uri);
      expect(controller.takeInitialRequest(), isNull);
    },
  );

  test(
    'builds a document-start webview_flutter JavaScript channel shim',
    () async {
      await controller.addJavaScriptChannel(
        webview.JavaScriptChannelParams(
          name: 'Flutter',
          onMessageReceived: (_) {},
        ),
      );

      final script = controller.initialUserScripts.single;
      expect(
        script.injectionTime,
        inapp.UserScriptInjectionTime.AT_DOCUMENT_START,
      );
      expect(script.source, contains('window[channelName]'));
      expect(script.source, contains('flutter_inappwebview.callHandler'));
      expect(script.source, contains('"Flutter"'));
    },
  );

  test(
    'applies navigation decisions to redirects and script navigations',
    () async {
      await navigationDelegate.setOnNavigationRequest((request) {
        return request.url.endsWith('/allowed')
            ? webview.NavigationDecision.navigate
            : webview.NavigationDecision.prevent;
      });
      await controller.setPlatformNavigationDelegate(navigationDelegate);

      final allowed = await controller.onNavigationAction(
        _navigationAction('https://accounts.example.com/allowed'),
      );
      final blocked = await controller.onNavigationAction(
        _navigationAction('https://example.com/redirect'),
      );

      expect(allowed, inapp.NavigationActionPolicy.ALLOW);
      expect(blocked, inapp.NavigationActionPolicy.CANCEL);
    },
  );

  test('maps HTTP Basic authentication credentials', () async {
    await navigationDelegate.setOnHttpAuthRequest((request) {
      expect(request.host, 'staging.example.com');
      expect(request.realm, 'staging');
      request.onProceed(
        const webview.WebViewCredential(user: 'alice', password: 'secret'),
      );
    });
    await controller.setPlatformNavigationDelegate(navigationDelegate);

    final response = await controller.onHttpAuthRequest(
      inapp.HttpAuthenticationChallenge(
        previousFailureCount: 0,
        protectionSpace: inapp.URLProtectionSpace(
          host: 'staging.example.com',
          realm: 'staging',
        ),
      ),
    );

    expect(response?.action, inapp.HttpAuthResponseAction.PROCEED);
    expect(response?.username, 'alice');
    expect(response?.password, 'secret');
  });

  test('maps combined camera and microphone permission requests', () async {
    Set<webview.WebViewPermissionResourceType>? requestedTypes;
    await controller.setOnPlatformPermissionRequest((request) {
      requestedTypes = request.types;
      request.grant();
    });

    final response = await controller.onPermissionRequest(
      inapp.PermissionRequest(
        origin: inapp.WebUri('https://media.example.com'),
        resources: <inapp.PermissionResourceType>[
          inapp.PermissionResourceType.CAMERA_AND_MICROPHONE,
        ],
      ),
    );

    expect(requestedTypes, <webview.WebViewPermissionResourceType>{
      webview.WebViewPermissionResourceType.camera,
      webview.WebViewPermissionResourceType.microphone,
    });
    expect(response?.action, inapp.PermissionResponseAction.GRANT);
  });
}

inapp.NavigationAction _navigationAction(String url) {
  return inapp.NavigationAction(
    isForMainFrame: true,
    isRedirect: true,
    request: inapp.URLRequest(url: inapp.WebUri(url)),
  );
}
