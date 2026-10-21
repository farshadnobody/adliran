package com.example.adl_notices_app

import android.Manifest
import android.content.pm.PackageManager
import android.telephony.SmsManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "adl/sms")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestPermission" -> {
                        if (granted()) {
                            result.success(true)
                        } else {
                            pending = result
                            ActivityCompat.requestPermissions(
                                this, arrayOf(Manifest.permission.SEND_SMS), 77
                            )
                        }
                    }
                    "send" -> {
                        try {
                            @Suppress("DEPRECATION")
                            val sms = SmsManager.getDefault()
                            sms.sendTextMessage(
                                call.argument<String>("to"), null,
                                call.argument<String>("text"), null, null
                            )
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SMS", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun granted() = ContextCompat.checkSelfPermission(
        this, Manifest.permission.SEND_SMS
    ) == PackageManager.PERMISSION_GRANTED

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 77) {
            pending?.success(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
            pending = null
        }
    }
}
