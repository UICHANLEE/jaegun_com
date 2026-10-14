package com.uichanlee.jaegun;

import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.AtomicFile;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.security.SecureRandom;
import java.util.Arrays;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.regex.Pattern;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import org.json.JSONObject;

@CapacitorPlugin(name = "JaegunSecureStorage")
public final class JaegunSecureStoragePlugin extends Plugin {
    private static final String AUTH_KEY = "sb-opwzujhfsxqaivtbjewg-auth-token";
    private static final String RECOVERY_KEY = "com.uichanlee.jaegun.password-recovery-intent.v1";
    private static final String SOCIAL_INTENT_KEY = "com.uichanlee.jaegun.social-auth-intent.v1";
    private static final Set<String> FIXED_KEYS = java.util.Collections.unmodifiableSet(
        new java.util.HashSet<>(Arrays.asList(AUTH_KEY, AUTH_KEY + "-user",
            AUTH_KEY + "-code-verifier", AUTH_KEY + "-flows-code-verifier", RECOVERY_KEY, SOCIAL_INTENT_KEY)));
    private static final Pattern FLOW_KEY = Pattern.compile(
        Pattern.quote(AUTH_KEY + "-flow-") + "[A-Za-z0-9_-]{8,64}-code-verifier");
    private static final String KEY_ALIAS = "com.uichanlee.jaegun.supabase-auth.v1";
    private static final String TRANSFORMATION = "AES/GCM/NoPadding";
    private static final int MAX_VALUE_BYTES = 1_048_576;
    private static final int IV_BYTES = 12;
    private static final int TAG_BITS = 128;
    private static final byte FORMAT_VERSION = 1;
    private final ExecutorService storageQueue = Executors.newSingleThreadExecutor();
    private File storageDirectory;
    private SecretKey encryptionKey;
    private boolean prepared;

    @PluginMethod
    public void prepare(PluginCall call) {
        execute(call, () -> { ensurePrepared(); call.resolve(); });
    }

    @PluginMethod
    public void get(PluginCall call) {
        String key = validatedKey(call);
        if (key == null) return;
        execute(call, () -> {
            ensurePrepared();
            AtomicFile file = storageFile(key);
            JSObject result = new JSObject();
            boolean exists = file.getBaseFile().exists()
                || new File(file.getBaseFile().getPath() + ".bak").exists();
            result.put("value", exists ? decodeUtf8(decrypt(file.readFully(), key)) : JSONObject.NULL);
            call.resolve(result);
        });
    }

    @PluginMethod
    public void set(PluginCall call) {
        String key = validatedKey(call);
        if (key == null) return;
        String value = call.getString("value");
        final byte[] data;
        try {
            if (value == null || value.length() > MAX_VALUE_BYTES) throw new CharacterCodingException();
            ByteBuffer bytes = StandardCharsets.UTF_8.newEncoder()
                .onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
                .encode(java.nio.CharBuffer.wrap(value));
            if (bytes.remaining() > MAX_VALUE_BYTES) throw new CharacterCodingException();
            data = new byte[bytes.remaining()];
            bytes.get(data);
        } catch (CharacterCodingException error) {
            call.reject("인증 저장소 값이 올바르지 않습니다.", "INVALID_STORAGE_VALUE");
            return;
        }
        execute(call, () -> {
            try {
                ensurePrepared();
                writeCiphertext(storageFile(key), encrypt(data, key));
                call.resolve();
            } finally {
                Arrays.fill(data, (byte) 0);
            }
        });
    }

    @PluginMethod
    public void remove(PluginCall call) {
        String key = validatedKey(call);
        if (key == null) return;
        execute(call, () -> {
            ensurePrepared();
            AtomicFile file = storageFile(key);
            file.delete();
            if (file.getBaseFile().exists()) throw new java.io.IOException();
            call.resolve();
        });
    }

    private String validatedKey(PluginCall call) {
        String key = call.getString("key");
        if (key != null && (FIXED_KEYS.contains(key) || FLOW_KEY.matcher(key).matches())) return key;
        call.reject("허용되지 않은 인증 저장소 키입니다.", "INVALID_STORAGE_KEY");
        return null;
    }

    private void ensurePrepared() throws Exception {
        if (prepared) return;
        // noBackupFilesDir is excluded from cloud backup AND device transfer. Android
        // removes this app's Keystore entries on uninstall; absent keys with remaining
        // ciphertext must never silently create a replacement or plaintext fallback.
        storageDirectory = new File(getContext().getNoBackupFilesDir(), "jaegun-auth-v1");
        if (!storageDirectory.isDirectory() && !storageDirectory.mkdirs()) throw new java.io.IOException();
        KeyStore keyStore = KeyStore.getInstance("AndroidKeyStore");
        keyStore.load(null);
        if (keyStore.containsAlias(KEY_ALIAS)) {
            encryptionKey = (SecretKey) keyStore.getKey(KEY_ALIAS, null);
        } else {
            String[] files = storageDirectory.list();
            if (files == null || files.length != 0) throw new java.security.GeneralSecurityException();
            KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
            generator.init(new KeyGenParameterSpec.Builder(KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).setRandomizedEncryptionRequired(true).build());
            encryptionKey = generator.generateKey();
        }
        if (encryptionKey == null) throw new java.security.GeneralSecurityException();
        byte[] probe = new byte[32];
        new SecureRandom().nextBytes(probe);
        AtomicFile probeFile = storageFile("__jaegun_crypto_probe_v1__");
        try {
            writeCiphertext(probeFile, encrypt(probe, "__jaegun_crypto_probe_v1__"));
            if (!Arrays.equals(probe, decrypt(probeFile.readFully(), "__jaegun_crypto_probe_v1__"))) {
                throw new java.security.GeneralSecurityException();
            }
            probeFile.delete();
            if (probeFile.getBaseFile().exists()) throw new java.io.IOException();
            prepared = true;
        } finally {
            Arrays.fill(probe, (byte) 0);
            probeFile.delete();
        }
    }

    private AtomicFile storageFile(String key) {
        return new AtomicFile(new File(storageDirectory, key + ".enc"));
    }

    private byte[] encrypt(byte[] data, String key) throws Exception {
        Cipher cipher = Cipher.getInstance(TRANSFORMATION);
        cipher.init(Cipher.ENCRYPT_MODE, encryptionKey);
        cipher.updateAAD(key.getBytes(StandardCharsets.UTF_8));
        byte[] iv = cipher.getIV();
        if (iv.length != IV_BYTES) throw new java.security.GeneralSecurityException();
        byte[] encrypted = cipher.doFinal(data);
        return ByteBuffer.allocate(1 + IV_BYTES + encrypted.length)
            .put(FORMAT_VERSION).put(iv).put(encrypted).array();
    }

    private byte[] decrypt(byte[] record, String key) throws Exception {
        if (record.length < 1 + IV_BYTES + TAG_BITS / 8
            || record.length > 1 + IV_BYTES + MAX_VALUE_BYTES + TAG_BITS / 8
            || record[0] != FORMAT_VERSION) throw new java.security.GeneralSecurityException();
        Cipher cipher = Cipher.getInstance(TRANSFORMATION);
        cipher.init(Cipher.DECRYPT_MODE, encryptionKey,
            new GCMParameterSpec(TAG_BITS, record, 1, IV_BYTES));
        cipher.updateAAD(key.getBytes(StandardCharsets.UTF_8));
        return cipher.doFinal(record, 1 + IV_BYTES, record.length - 1 - IV_BYTES);
    }

    private String decodeUtf8(byte[] data) throws CharacterCodingException {
        try {
            return StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(data)).toString();
        } finally {
            Arrays.fill(data, (byte) 0);
        }
    }

    private void writeCiphertext(AtomicFile file, byte[] ciphertext) throws java.io.IOException {
        FileOutputStream stream = null;
        try {
            stream = file.startWrite();
            stream.write(ciphertext);
            file.finishWrite(stream);
        } catch (java.io.IOException error) {
            if (stream != null) file.failWrite(stream);
            throw error;
        }
    }

    private interface StorageOperation { void run() throws Exception; }

    private void execute(PluginCall call, StorageOperation operation) {
        storageQueue.execute(() -> {
            try {
                operation.run();
            } catch (Exception error) {
                // Never expose keys, credentials, ciphertext, or crypto details to JS/logs.
                call.reject("안전한 인증 저장소를 사용할 수 없습니다.", "SECURE_STORAGE_UNAVAILABLE");
            }
        });
    }

    @Override
    protected void handleOnDestroy() {
        storageQueue.shutdown();
    }
}
