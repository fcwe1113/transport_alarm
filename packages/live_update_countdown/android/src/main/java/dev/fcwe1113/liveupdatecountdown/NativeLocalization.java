package dev.fcwe1113.liveupdatecountdown;

import android.content.Context;
import android.content.SharedPreferences;

import org.json.JSONObject;

import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.Map;

/** Reads the app's shared English/string catalog from Flutter assets. */
final class NativeLocalization {
    private NativeLocalization() {}

    static String text(Context context, String key) {
        return text(context, key, null);
    }

    static String text(Context context, String key, Map<String, ?> values) {
        SharedPreferences preferences = context.getSharedPreferences(
                "FlutterSharedPreferences", Context.MODE_PRIVATE);
        String languageCode = preferences.getString("flutter.app_language_code", "en");
        JSONObject catalog = load(context, languageCode);
        if (catalog == null) catalog = load(context, "en");
        String value = catalog == null ? key : catalog.optString(key, key);
        if (values != null) {
            for (Map.Entry<String, ?> entry : values.entrySet()) {
                value = value.replace("{" + entry.getKey() + "}",
                        String.valueOf(entry.getValue()));
            }
        }
        return value;
    }

    private static JSONObject load(Context context, String languageCode) {
        try (InputStream input = context.getAssets().open(
                "strings_" + languageCode + ".json")) {
            byte[] bytes = new byte[input.available()];
            int count = input.read(bytes);
            return new JSONObject(new String(bytes, 0, count, StandardCharsets.UTF_8));
        } catch (Exception ignored) {
            return null;
        }
    }
}
