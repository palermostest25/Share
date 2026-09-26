package dev.denby.share;

import android.app.Activity;
import android.app.AlertDialog;
import android.app.DownloadManager;
import android.content.ActivityNotFoundException;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.os.Environment;
import android.os.Build;
import android.graphics.Insets;
import android.view.Menu;
import android.view.MenuItem;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.webkit.CookieManager;
import android.webkit.DownloadListener;
import android.webkit.URLUtil;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.Toast;

import java.net.URI;

public final class MainActivity extends Activity {
    private static final int PICK_FILE = 42;
    private static final String REMOTE = "https://share.denby.dev";
    private WebView browser;
    private ProgressBar progress;
    private ValueCallback<Uri[]> fileCallback;
    private String base;

    @Override public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        base = getPreferences(MODE_PRIVATE).getString("server", REMOTE);
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        layout.setOnApplyWindowInsetsListener((view, windowInsets) -> {
            int top;
            int bottom;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                Insets bars = windowInsets.getInsets(WindowInsets.Type.systemBars());
                top = bars.top;
                bottom = bars.bottom;
            } else {
                top = windowInsets.getSystemWindowInsetTop();
                bottom = windowInsets.getSystemWindowInsetBottom();
            }
            view.setPadding(0, top, 0, bottom);
            return windowInsets;
        });
        progress = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        progress.setMax(100);
        progress.setVisibility(View.GONE);
        layout.addView(progress, new LinearLayout.LayoutParams(-1, 3));
        browser = new WebView(this);
        layout.addView(browser, new LinearLayout.LayoutParams(-1, 0, 1));
        setContentView(layout);
        layout.requestApplyInsets();

        WebSettings settings = browser.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setAllowFileAccess(false);
        settings.setAllowContentAccess(true);
        settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        settings.setMediaPlaybackRequiresUserGesture(false);
        settings.setSupportMultipleWindows(false);
        settings.setJavaScriptCanOpenWindowsAutomatically(true);
        browser.setWebViewClient(new WebViewClient() {
            @Override public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                if (!request.isForMainFrame()) return false;
                Uri url = request.getUrl();
                if (sameOrigin(url)) return false;
                openOutside(url);
                return true;
            }
        });
        browser.setWebChromeClient(new WebChromeClient() {
            @Override public boolean onShowFileChooser(WebView view, ValueCallback<Uri[]> callback, FileChooserParams params) {
                if (fileCallback != null) fileCallback.onReceiveValue(null);
                fileCallback = callback;
                try { startActivityForResult(params.createIntent(), PICK_FILE); }
                catch (ActivityNotFoundException e) {
                    fileCallback = null;
                    callback.onReceiveValue(null);
                    Toast.makeText(MainActivity.this, "No file picker is available", Toast.LENGTH_LONG).show();
                    return false;
                }
                return true;
            }
            @Override public void onProgressChanged(WebView view, int value) {
                progress.setProgress(value);
                progress.setVisibility(value >= 100 ? View.GONE : View.VISIBLE);
            }
        });
        browser.setDownloadListener((url, userAgent, disposition, mime, length) -> {
            Uri uri = Uri.parse(url);
            if (!sameOrigin(uri)) { openOutside(uri); return; }
            try {
                DownloadManager.Request request = new DownloadManager.Request(uri);
                request.setTitle(URLUtil.guessFileName(url, disposition, mime));
                request.setMimeType(mime);
                request.setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED);
                request.setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, URLUtil.guessFileName(url, disposition, mime));
                ((DownloadManager) getSystemService(DOWNLOAD_SERVICE)).enqueue(request);
                Toast.makeText(this, "Download started", Toast.LENGTH_SHORT).show();
            } catch (Exception e) { Toast.makeText(this, "Download failed: " + e.getMessage(), Toast.LENGTH_LONG).show(); }
        });
        browser.loadUrl(base);
    }

    private boolean sameOrigin(Uri url) {
        Uri allowed = Uri.parse(base);
        return allowed.getScheme().equalsIgnoreCase(url.getScheme()) &&
                allowed.getHost().equalsIgnoreCase(url.getHost()) &&
                allowed.getPort() == url.getPort();
    }

    private void openOutside(Uri url) {
        try { startActivity(new Intent(Intent.ACTION_VIEW, url)); }
        catch (ActivityNotFoundException e) { Toast.makeText(this, "No app can open this link", Toast.LENGTH_LONG).show(); }
    }

    @Override protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode != PICK_FILE || fileCallback == null) return;
        fileCallback.onReceiveValue(WebChromeClient.FileChooserParams.parseResult(resultCode, data));
        fileCallback = null;
    }

    @Override public void onBackPressed() {
        if (browser.canGoBack()) browser.goBack(); else super.onBackPressed();
    }

    @Override public boolean onCreateOptionsMenu(Menu menu) {
        menu.add(0, 1, 0, "Refresh");
        menu.add(0, 2, 1, "Server address");
        menu.add(0, 3, 2, "Open in browser");
        return true;
    }

    @Override public boolean onOptionsItemSelected(MenuItem item) {
        if (item.getItemId() == 1) { browser.reload(); return true; }
        if (item.getItemId() == 3) { openOutside(Uri.parse(base)); return true; }
        if (item.getItemId() != 2) return super.onOptionsItemSelected(item);
        EditText input = new EditText(this);
        input.setSingleLine(true);
        input.setText(base);
        new AlertDialog.Builder(this).setTitle("Share server").setMessage("Use HTTPS remotely. Private LAN HTTP is allowed on a trusted network.")
                .setView(input).setNegativeButton("Cancel", null).setPositiveButton("Connect", (dialog, which) -> {
                    String candidate = input.getText().toString().trim().replaceAll("/+$", "");
                    if (!validServer(candidate)) { Toast.makeText(this, "Enter an HTTPS URL or private LAN HTTP address", Toast.LENGTH_LONG).show(); return; }
                    base = candidate;
                    getPreferences(MODE_PRIVATE).edit().putString("server", base).apply();
                    browser.clearHistory();
                    browser.loadUrl(base);
                }).show();
        return true;
    }

    private boolean validServer(String value) {
        try {
            URI uri = new URI(value);
            if (uri.getHost() == null || uri.getUserInfo() != null || uri.getQuery() != null || uri.getFragment() != null ||
                    (uri.getPath() != null && !uri.getPath().isEmpty())) return false;
            if ("https".equalsIgnoreCase(uri.getScheme())) return true;
            if (!"http".equalsIgnoreCase(uri.getScheme())) return false;
            String host = uri.getHost().toLowerCase();
            if (host.equals("localhost") || host.endsWith(".local")) return true;
            String[] parts = host.split("\\.");
            if (parts.length != 4) return false;
            int[] ip = new int[4];
            for (int i = 0; i < 4; i++) { ip[i] = Integer.parseInt(parts[i]); if (ip[i] < 0 || ip[i] > 255) return false; }
            return ip[0] == 10 || ip[0] == 127 || ip[0] == 192 && ip[1] == 168 || ip[0] == 172 && ip[1] >= 16 && ip[1] <= 31;
        } catch (Exception e) { return false; }
    }

    @Override protected void onDestroy() {
        if (fileCallback != null) fileCallback.onReceiveValue(null);
        browser.destroy();
        super.onDestroy();
    }
}
