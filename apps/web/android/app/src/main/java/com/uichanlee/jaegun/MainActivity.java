package com.uichanlee.jaegun;

import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.view.WindowManager;
import android.webkit.WebSettings;
import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    @Override
    public void onCreate(Bundle savedInstanceState) {
        registerPlugin(JaegunSecureStoragePlugin.class);
        sanitizeAuthIntent(getIntent());
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            setRecentsScreenshotEnabled(false);
        }
        super.onCreate(savedInstanceState);
        if (bridge != null && bridge.getWebView() != null) {
            WebSettings settings = bridge.getWebView().getSettings();
            settings.setAllowFileAccess(false);
            settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                settings.setAlgorithmicDarkeningAllowed(false);
            }
        }
    }

    @Override
    public void onPause() {
        // Protect background snapshots without disabling foreground screen capture.
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
        super.onPause();
    }

    @Override
    public void onResume() {
        super.onResume();
        getWindow().clearFlags(WindowManager.LayoutParams.FLAG_SECURE);
    }

    @Override
    protected void onNewIntent(Intent intent) {
        sanitizeAuthIntent(intent);
        super.onNewIntent(intent);
    }

    private void sanitizeAuthIntent(Intent intent) {
        if (intent == null || intent.getData() == null) return;
        Uri uri = intent.getData();
        String path = uri.getEncodedPath();
        boolean allowed = Intent.ACTION_VIEW.equals(intent.getAction())
            && uri.toString().length() <= 4_096
            && "https".equals(uri.getScheme())
            && "jaegun-com.vercel.app".equals(uri.getHost())
            && uri.getUserInfo() == null
            && uri.getPort() == -1
            && uri.getFragment() == null
            && "/auth/callback/social".equals(path)
            && (uri.toString().equals("https://jaegun-com.vercel.app/auth/callback/social")
                || uri.toString().startsWith("https://jaegun-com.vercel.app/auth/callback/social?"));
        if (!allowed) intent.setData(null);
    }
}
