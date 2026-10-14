package com.uichanlee.jaegun;

import static org.junit.Assert.*;

import androidx.test.core.app.ActivityScenario;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import com.getcapacitor.JSObject;
import com.getcapacitor.PluginCall;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Arrays;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;

@RunWith(AndroidJUnit4.class)
public final class SecureStorageInstrumentedTest {
    private static final String KEY = "sb-opwzujhfsxqaivtbjewg-auth-token-flow-android_test_v1-code-verifier";
    private static final String OTHER_KEY = "sb-opwzujhfsxqaivtbjewg-auth-token-flow-android_test_v2-code-verifier";
    private static final String SOCIAL_KEY = "com.uichanlee.jaegun.social-auth-intent.v1";
    private ActivityScenario<MainActivity> scenario;
    private JaegunSecureStoragePlugin plugin;
    private File directory;

    private static final class Call extends PluginCall {
        private final CountDownLatch completed = new CountDownLatch(1);
        private JSObject result;
        private String error;
        Call(JSObject data) { super(null, "JaegunSecureStorage", "instrumented-test", "test", data); }
        @Override public void resolve() { completed.countDown(); }
        @Override public void resolve(JSObject data) { result = data; completed.countDown(); }
        @Override public void reject(String message, String code) { error = code; completed.countDown(); }
        Call await() throws Exception {
            assertTrue("Native bridge must respond", completed.await(10, TimeUnit.SECONDS));
            return this;
        }
    }

    @Before public void launchRealActivity() throws Exception {
        scenario = ActivityScenario.launch(MainActivity.class);
        scenario.onActivity(activity -> {
            plugin = (JaegunSecureStoragePlugin) activity.getBridge().getPlugin("JaegunSecureStorage").getInstance();
            directory = new File(activity.getNoBackupFilesDir(), "jaegun-auth-v1");
        });
        Call prepare = new Call(new JSObject());
        plugin.prepare(prepare);
        assertNull(prepare.await().error);
        remove(KEY);
        remove(OTHER_KEY);
        remove(SOCIAL_KEY);
    }

    @After public void closeActivity() throws Exception {
        if (plugin != null) { remove(KEY); remove(OTHER_KEY); remove(SOCIAL_KEY); }
        if (scenario != null) scenario.close();
    }

    private void remove(String key) throws Exception {
        Call call = new Call(new JSObject().put("key", key));
        plugin.remove(call);
        assertNull(call.await().error);
    }

    private Call set(String key, String value) throws Exception {
        Call call = new Call(new JSObject().put("key", key).put("value", value));
        plugin.set(call);
        return call.await();
    }

    private Call get(String key) throws Exception {
        Call call = new Call(new JSObject().put("key", key));
        plugin.get(call);
        return call.await();
    }

    @Test public void roundTripPersistsOnlyRandomizedCiphertext() throws Exception {
        String value = "native-crypto-check-비밀-123456789";
        assertNull(set(KEY, value).error);
        File file = new File(directory, KEY + ".enc");
        byte[] first = Files.readAllBytes(file.toPath());
        assertFalse(new String(first, StandardCharsets.UTF_8).contains(value));
        assertEquals(value, get(KEY).result.getString("value"));
        assertNull(set(KEY, value).error);
        assertFalse("AES-GCM must generate a fresh IV", Arrays.equals(first, Files.readAllBytes(file.toPath())));
        scenario.recreate();
        scenario.onActivity(activity -> plugin = (JaegunSecureStoragePlugin)
            activity.getBridge().getPlugin("JaegunSecureStorage").getInstance());
        assertEquals("Ciphertext must survive native activity recreation", value, get(KEY).result.getString("value"));
        remove(KEY);
        assertTrue(get(KEY).result.isNull("value"));
    }

    @Test public void socialIntentPersistsOnlyAtExactSecureKey() throws Exception {
        String value = "{\"intentId\":\"native_intent_nonce_12345678\",\"provider\":\"google\"}";
        assertNull(set(SOCIAL_KEY, value).error);
        File file = new File(directory, SOCIAL_KEY + ".enc");
        assertFalse(new String(Files.readAllBytes(file.toPath()), StandardCharsets.UTF_8).contains(value));
        scenario.recreate();
        scenario.onActivity(activity -> plugin = (JaegunSecureStoragePlugin)
            activity.getBridge().getPlugin("JaegunSecureStorage").getInstance());
        assertEquals(value, get(SOCIAL_KEY).result.getString("value"));
        assertEquals("INVALID_STORAGE_KEY", set(SOCIAL_KEY + ".other", value).error);
        assertEquals("INVALID_STORAGE_KEY", set(SOCIAL_KEY + "-code-verifier", value).error);
        remove(SOCIAL_KEY);
        assertTrue(get(SOCIAL_KEY).result.isNull("value"));
    }

    @Test public void rejectsKeysAndUtf8OversizeValues() throws Exception {
        for (String key : new String[] {"unrelated", "../auth", "sb-opwzujhfsxqaivtbjewg-auth-token-flow-short-code-verifier",
            "sb-opwzujhfsxqaivtbjewg-auth-token-flow-12345678.-code-verifier"}) {
            assertEquals("INVALID_STORAGE_KEY", set(key, "value").error);
        }
        char[] oversized = new char[349_526];
        Arrays.fill(oversized, '가');
        assertEquals("INVALID_STORAGE_VALUE", set(KEY, new String(oversized)).error);
        assertTrue(get(KEY).result.isNull("value"));
    }

    @Test public void tamperingAndCrossKeyCiphertextFailClosed() throws Exception {
        assertNull(set(KEY, "authenticated-ciphertext").error);
        File file = new File(directory, KEY + ".enc");
        byte[] bytes = Files.readAllBytes(file.toPath());
        Files.write(new File(directory, OTHER_KEY + ".enc").toPath(), bytes);
        assertEquals("SECURE_STORAGE_UNAVAILABLE", get(OTHER_KEY).error);
        bytes[bytes.length - 1] ^= 1;
        Files.write(file.toPath(), bytes);
        assertEquals("SECURE_STORAGE_UNAVAILABLE", get(KEY).error);
    }
}
