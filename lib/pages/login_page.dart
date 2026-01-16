import 'dart:async'; // Required for Timer and Future
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';

import '../services/language_service.dart';
import '../utils/api_urls.dart'; 

class LoginPage extends StatefulWidget {
  final String url;
  final bool isLogout;

  const LoginPage({
    Key? key, 
    required this.url, 
    this.isLogout = false 
  }) : super(key: key);

  @override
  _LoginPageState createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  late final WebViewController _controller;
  
  // Start loading true by default
  bool _isLoading = true;
  bool _isPageLoaded = false;
  
  // Flag to manage the logout transition logic
  bool _hasLogoutRedirected = false;

  late LanguageService _languageService;

  @override
  void initState() {
    super.initState();
    _initWebView();
    
    // Defer adding the listener until after the first build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _languageService.addListener(_onLanguageChanged);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Capture the service reference here to safely use in dispose
    _languageService = Provider.of<LanguageService>(context, listen: false);
  }

  @override
  void dispose() {
    _languageService.removeListener(_onLanguageChanged);
    super.dispose();
  }

  void _onLanguageChanged() {
    if (!mounted || !_isPageLoaded) return;
    _syncWebLanguage(_languageService.currentLanguage);
  }

  void _initWebView() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // FIX: Setting background color avoids "black flashes" on iOS during load
      ..setBackgroundColor(Colors.white) 
      ..addJavaScriptChannel(
        'PrintChannel',
        onMessageReceived: (JavaScriptMessage message) {
          if (message.message == 'print_trigger') {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text("Print requested! Please share the receipt PDF to this app."),
                backgroundColor: Colors.green,
                duration: Duration(seconds: 4),
              ),
            );
          }
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) {
            if (mounted) setState(() => _isLoading = true);
            _isPageLoaded = false;
          },
          onPageFinished: (String url) {
            // --- FIX FOR SMOOTHNESS ---
            // If we are in "Logout Mode" and haven't redirected to login yet,
            // KEEP the loading spinner visible. Do not let the user see the
            // intermediate blank page of the logout API call.
            if (widget.isLogout && !_hasLogoutRedirected) {
              return; 
            }

            if (mounted) setState(() => _isLoading = false);
            _isPageLoaded = true;

            // Sync language when page finishes loading
            _syncWebLanguage(_languageService.currentLanguage);
            _checkLoginStatus(url);

            // Inject JS for printing support
            _controller.runJavaScript('''
              window.print = function() {
                  if(window.PrintChannel) {
                    PrintChannel.postMessage('print_trigger');
                  }
              }
            ''');
          },
          onUrlChange: (UrlChange change) {
            if (change.url != null) {
              _checkLoginStatus(change.url!);
            }
          },
          onWebResourceError: (WebResourceError error) {
             // Ignore errors during the logout redirect sequence
             if (widget.isLogout) {
               debugPrint("Ignored error during logout: ${error.description}");
             }
          },
        ),
      );

    if (widget.isLogout) {
       // --- LOGOUT SEQUENCE ---
       // 1. Call logout to clear session on Odoo server
       _controller.loadRequest(Uri.parse('${widget.url}/session/logout'));

       // 2. Wait 2 seconds, then FORCE redirect to Login.
       // The opaque loading screen stays ON during this time.
       Future.delayed(const Duration(seconds: 2), () {
         if (mounted && !_hasLogoutRedirected) {
           _hasLogoutRedirected = true;
           debugPrint("Force redirecting to login page...");
           _controller.loadRequest(Uri.parse('${widget.url}/login'));
         }
       });

    } else {
       // --- NORMAL STARTUP ---
       _controller.loadRequest(Uri.parse('${widget.url}/login')); 
    }
  }

  // Polling Mechanism for Odoo SPA Language Switching
  void _syncWebLanguage(String appLanguageCode) {
    String targetWebValue = (appLanguageCode == 'ms') ? 'ms_MY' : 'en_US';

    String jsCode = """
      (function() {
        var attempts = 0;
        var maxAttempts = 20; 
        var targetValue = "$targetWebValue";

        var interval = setInterval(function() {
          attempts++;
          // Look for the Odoo language button
          var btn = document.querySelector('button[value="' + targetValue + '"]');

          if (btn) {
            // console.log('Flutter: Found button for ' + targetValue + ', clicking now.');
            btn.click();
            clearInterval(interval); 
          } else {
            if (attempts >= maxAttempts) {
               clearInterval(interval);
            }
          }
        }, 500); // Check every 500ms
      })();
    """;

    _controller.runJavaScript(jsCode);
  }

  void _checkLoginStatus(String url) async {
    if (!mounted) return;
    
    // Don't log in if we are in the middle of a logout sequence
    if (widget.isLogout && !_hasLogoutRedirected) return;
    if (url.contains('session/logout')) return;

    // Define what constitutes a "Login Page" (so we don't redirect away from it)
    bool isLoginPage = url.contains('/login') || 
                       url.contains('/signin') || 
                       url.contains('reset_password') ||
                       url.contains('auth_signup');
    
    // Define what constitutes the "Backend/Logged In" state
    bool isOdooBackend = url.contains('/web') || url.contains('/pos/ui');

    if (url.startsWith(widget.url) && !isLoginPage && isOdooBackend) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('is_logged_in', true);
      await prefs.setString('env_url', widget.url);
      
      if (mounted) {
        Navigator.of(context).pushReplacementNamed('/home');
      }
    }
  }

  Future<void> _handleClearCache() async {
    final cookieManager = WebViewCookieManager();
    await cookieManager.clearCookies();
    await _controller.clearCache();
    await _controller.clearLocalStorage();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_languageService.translate('msg_cache_cleared'))),
      );
      _controller.reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    // We can use Provider.of here because build is always called with valid context
    final lang = Provider.of<LanguageService>(context);

    return Scaffold(
      // FIX: CRITICAL FOR IOS: Prevents the UI from resizing/jumping when the keyboard opens
      resizeToAvoidBottomInset: false, 
      
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/images/menu_icon.png', 
              height: 30, 
              fit: BoxFit.contain,
            ),
            const SizedBox(width: 10),
            Text(lang.translate('title_login'), style: const TextStyle(fontSize: 15)),
          ],
        ),
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: "Clear Cache",
            onPressed: _handleClearCache,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: "Refresh Page",
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(lang.translate('msg_reloading'))),
              );
              _controller.reload();
            },
          ),
          const SizedBox(width: 5),
        ],
      ),
      body: Stack(
        children: [
          // 1. The actual WebView
          WebViewWidget(controller: _controller),
          
          // 2. Opaque Loading Overlay
          // FIX: Using an opaque container instead of just a spinner helps hide 
          // rendering glitches and white flashes on iOS.
          if (_isLoading)
            Container(
              color: Colors.white, 
              width: double.infinity,
              height: double.infinity,
              child: const Center(
                child: CircularProgressIndicator(),
              ),
            ),
        ],
      ),
    );
  }
}