class ApiUrls {
  static const String dev = 'https://epos17-dev.apeglobe.com/web';
  static const String uat = 'https://uat.epos.myinvois.hasil.gov.my/web';
  static const String preProd = 'https://preprod.epos.myinvois.hasil.gov.my/web';
  static const String production = 'https://epos.myinvois.hasil.gov.my/web';

  // Logout URLs
  static const String devLogout = 'https://epos17-dev.apeglobe.com/web/session/logout';
  static const String uatLogout = 'https://uat.epos.myinvois.hasil.gov.my/web/session/logout';
  static const String preProdLogout = 'https://preprod.epos.myinvois.hasil.gov.my/web/session/logout';
  static const String productionLogout = 'https://epos.myinvois.hasil.gov.my/web/session/logout';

  static Map<String, String> get environments => {
    'Production': production,
    'Pre-Prod': preProd,
    'UAT': uat,
    'DEV': dev,
  };
  
  static String getLogoutUrl(String baseUrl) {
    // Remove trailing slash for cleaner comparison
    String cleanUrl = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    
    if (cleanUrl == dev) return devLogout;
    if (cleanUrl == uat) return uatLogout;
    if (cleanUrl == preProd) return preProdLogout;
    if (cleanUrl == production) return productionLogout;
    
    // Fallback: Append standard Odoo logout path
    return '$cleanUrl/session/logout';
  }
}