import type { CapacitorConfig } from "@capacitor/cli";

const config: CapacitorConfig = {
  // This is a reversible local identifier until the organization's Apple
  // Developer Team confirms the final App ID in Certificates, IDs & Profiles.
  appId: "com.uichanlee.jaegun",
  appName: "재건 공동체",
  webDir: "dist",
  loggingBehavior: "none",
  backgroundColor: "#f7f4ee",
  zoomEnabled: false,
  ios: {
    path: "ios",
    scheme: "App",
    contentInset: "never",
    scrollEnabled: true,
    allowsLinkPreview: false,
    preferredContentMode: "mobile",
    webContentsDebuggingEnabled: false,
    handleApplicationNotifications: false,
    includePlugins: [
      "@capacitor/app",
      "@capacitor/browser",
      "@capacitor/keyboard",
      "@capacitor/network",
      "@capacitor/splash-screen",
      "@capacitor/status-bar",
    ],
  },
  server: {
    hostname: "localhost",
    iosScheme: "capacitor",
    cleartext: false,
    allowNavigation: [],
  },
  // Keep Cordova's generated config.xml fail-closed as well. Capacitor uses
  // server.allowNavigation for WebView navigation, while this separate list is
  // consumed only by Cordova plugins that honor the network access whitelist.
  cordova: {
    accessOrigins: ["https://opwzujhfsxqaivtbjewg.supabase.co"],
  },
  plugins: {
    SplashScreen: {
      launchAutoHide: true,
      launchShowDuration: 800,
      backgroundColor: "#f7f4ee",
      showSpinner: false,
    },
    StatusBar: {
      overlaysWebView: false,
      style: "DARK",
      backgroundColor: "#f7f4ee",
    },
    Keyboard: {
      resize: "native",
      style: "LIGHT",
      resizeOnFullScreen: true,
    },
  },
};

export default config;
