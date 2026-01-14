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
    if (baseUrl == dev) return devLogout;
    if (baseUrl == uat) return uatLogout;
    if (baseUrl == preProd) return preProdLogout;
    return productionLogout;
  }
}