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
  bool _isLoading = true;
  bool _isPageLoaded = false;
  
  // FIX 1: Store reference to service to safely dispose later
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
    // FIX 1: Capture the service reference here, while context is valid
    _languageService = Provider.of<LanguageService>(context, listen: false);
  }

  @override
  void dispose() {
    // FIX 1: Use the captured reference instead of context.read()
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
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) {
            if (mounted) setState(() => _isLoading = true);
            _isPageLoaded = false;
          },
          onPageFinished: (String url) {
            if (mounted) setState(() => _isLoading = false);
            _isPageLoaded = true;

            // Sync language when page finishes loading
            _syncWebLanguage(_languageService.currentLanguage);
            _checkLoginStatus(url);
          },
          onUrlChange: (UrlChange change) {
            if (change.url != null) {
              _checkLoginStatus(change.url!);
            }
          },
        ),
      );

    if (widget.isLogout) {
       _controller.loadRequest(Uri.parse('${widget.url}/session/logout'));
    } else {
       _controller.loadRequest(Uri.parse('${widget.url}/login')); 
    }
  }

  // FIX 2: Polling Mechanism for Odoo SPA
  void _syncWebLanguage(String appLanguageCode) {
    String targetWebValue = (appLanguageCode == 'ms') ? 'ms_MY' : 'en_US';

    // We use setInterval to check every 500ms if the button exists.
    // We try for max 20 times (10 seconds) before giving up.
    String jsCode = """
      (function() {
        var attempts = 0;
        var maxAttempts = 20; 
        var targetValue = "$targetWebValue";

        var interval = setInterval(function() {
          attempts++;
          // Look for the button with the specific value
          var btn = document.querySelector('button[value="' + targetValue + '"]');

          if (btn) {
            console.log('Flutter: Found button for ' + targetValue + ', clicking now.');
            btn.click();
            clearInterval(interval); // Stop checking
          } else {
            console.log('Flutter: Searching for button... Attempt ' + attempts);
            if (attempts >= maxAttempts) {
               console.log('Flutter: Button not found after timeout.');
               clearInterval(interval);
            }
          }
        }, 500); // Check every 500ms
      })();
    """;

    _controller.runJavaScript(jsCode);
  }

  void _checkLoginStatus(String url) async {
    if (!mounted) return; // Guard against async context use
    
    if (url.contains('/logout')) return;
    bool isLoginPage = url.contains('/login') || url.contains('/signin');
    
    if (!isLoginPage && url.startsWith(widget.url)) {
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
      // Use the captured reference here as well to be safe, though context is usually fine here
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
          WebViewWidget(controller: _controller),
          if (_isLoading)
            const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}