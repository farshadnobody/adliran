package com.example.adl_notices_app

import android.Manifest
import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "adl/sms")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestPermission" -> {
                        val missing = listOf(Manifest.permission.SEND_SMS, Manifest.permission.READ_PHONE_STATE)
                            .filter { !has(it) }
                        if (missing.isEmpty()) {
                            result.success(true)
                        } else {
                            pending = result
                            ActivityCompat.requestPermissions(this, missing.toTypedArray(), 77)
                        }
                    }
                    "sims" -> result.success(
                        subscriptions().filter { it.first != null }
                            .map { mapOf("id" to it.first, "name" to it.second) }
                    )
                    "send" -> send(
                        call.argument<String>("to") ?: "",
                        call.argument<String>("text") ?: "",
                        call.argument<Int>("subId"),
                        result
                    )
                    else -> result.notImplemented()
                }
            }
    }

    private fun has(p: String) =
        ContextCompat.checkSelfPermission(this, p) == PackageManager.PERMISSION_GRANTED

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 77) {
            // فقط SEND_SMS الزامی است؛ READ_PHONE_STATE برای انتخاب سیم‌کارت اختیاری است
            pending?.success(has(Manifest.permission.SEND_SMS))
            pending = null
        }
    }

    /** سیم‌کارت‌های فعال: اول پیش‌فرض پیامک، بعد بقیه. اگر مجوز نباشد فقط پیش‌فرض (null). */
    private fun subscriptions(): List<Pair<Int?, String>> {
        val out = mutableListOf<Pair<Int?, String>>()
        try {
            if (has(Manifest.permission.READ_PHONE_STATE)) {
                val sm = getSystemService(Context.TELEPHONY_SUBSCRIPTION_SERVICE) as SubscriptionManager
                val def = SubscriptionManager.getDefaultSmsSubscriptionId()
                val list = sm.activeSubscriptionInfoList ?: emptyList()
                val sorted = list.sortedBy { if (it.subscriptionId == def) 0 else 1 }
                for (i in sorted) {
                    val tag = if (i.subscriptionId == def) " (پیش‌فرض پیامک)" else ""
                    out.add(Pair(i.subscriptionId, "سیم ${i.simSlotIndex + 1} ${i.carrierName}$tag"))
                }
            }
        } catch (_: Exception) {
        }
        if (out.isEmpty()) out.add(Pair(null, "سیم پیش‌فرض"))
        return out
    }

    private fun send(to: String, text: String, chosen: Int?, result: MethodChannel.Result) {
        val log = mutableListOf<String>()
        val all = subscriptions()
        // اگر کاربر سیم‌کارت را انتخاب کرده فقط همان؛ وگرنه اول پیش‌فرض و بعد بقیه
        val subs = if (chosen != null) all.filter { it.first == chosen }.ifEmpty { all } else all
        log.add("سیم‌کارت‌های قابل استفاده: ${subs.joinToString { it.second }}")
        fun next(idx: Int) {
            if (idx >= subs.size) {
                result.success(mapOf("ok" to false, "log" to log))
                return
            }
            val (subId, name) = subs[idx]
            attempt(subId, to, text) { code, detail ->
                log.add("$name: ${codeName(code)}${if (detail.isEmpty()) "" else " ($detail)"}")
                if (code == Activity.RESULT_OK) {
                    result.success(mapOf("ok" to true, "log" to log))
                } else {
                    next(idx + 1)
                }
            }
        }
        next(0)
    }

    private fun attempt(subId: Int?, to: String, text: String, done: (Int, String) -> Unit) {
        val action = "adl.SMS_SENT.${System.nanoTime()}"
        var finished = false
        lateinit var receiver: BroadcastReceiver
        fun finish(code: Int, detail: String) {
            if (finished) return
            finished = true
            try { unregisterReceiver(receiver) } catch (_: Exception) {}
            done(code, detail)
        }
        receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                finish(resultCode, if (resultCode == Activity.RESULT_OK) "" else "errorCode=${i.getIntExtra("errorCode", -1)}")
            }
        }
        try {
            val filter = IntentFilter(action)
            if (Build.VERSION.SDK_INT >= 33) {
                registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                registerReceiver(receiver, filter)
            }
            val pi = PendingIntent.getBroadcast(
                this, 0, Intent(action).setPackage(packageName),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_ONE_SHOT
            )
            @Suppress("DEPRECATION")
            val sms: SmsManager = when {
                subId != null -> SmsManager.getSmsManagerForSubscriptionId(subId)
                Build.VERSION.SDK_INT >= 31 -> getSystemService(SmsManager::class.java)
                else -> SmsManager.getDefault()
            }
            sms.sendTextMessage(to, null, text, pi, null)
            main.postDelayed({ finish(TIMEOUT, "پاسخی از سیستم نیامد") }, 25000)
        } catch (e: Exception) {
            finish(EXCEPTION, "${e.javaClass.simpleName}: ${e.message}")
        }
    }

    private fun codeName(c: Int) = when (c) {
        Activity.RESULT_OK -> "ارسال شد"
        SmsManager.RESULT_ERROR_GENERIC_FAILURE -> "GENERIC_FAILURE"
        SmsManager.RESULT_ERROR_RADIO_OFF -> "RADIO_OFF"
        SmsManager.RESULT_ERROR_NULL_PDU -> "NULL_PDU"
        SmsManager.RESULT_ERROR_NO_SERVICE -> "NO_SERVICE"
        5 -> "LIMIT_EXCEEDED"
        6 -> "FDN_CHECK_FAILURE"
        7 -> "SHORT_CODE_NOT_ALLOWED (تأیید ارسال به شماره‌ی کوتاه داده نشد)"
        8 -> "SHORT_CODE_NEVER_ALLOWED"
        10 -> "SMS_SEND_RETRY_FAILED"
        11 -> "REMOTE_EXCEPTION"
        12 -> "NO_DEFAULT_SMS_APP"
        TIMEOUT -> "TIMEOUT"
        EXCEPTION -> "EXCEPTION"
        else -> "کد $c"
    }

    companion object {
        private const val TIMEOUT = -999
        private const val EXCEPTION = -998
    }
}
