package id.walt.walletdemo.compose.android

import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.credentials.CredentialManager
import androidx.credentials.ExperimentalDigitalCredentialApi
import androidx.credentials.GetCredentialRequest
import androidx.credentials.GetCredentialResponse
import androidx.credentials.GetDigitalCredentialOption
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

internal const val EXTRA_REQUEST_ID = "id.walt.walletdemo.compose.android.extra.REQUEST_ID"
internal const val EXTRA_REQUEST_JSON = "id.walt.walletdemo.compose.android.extra.REQUEST_JSON"

/** Debug-only native verifier used by the Digital Credentials instrumentation E2E. */
@OptIn(ExperimentalDigitalCredentialApi::class)
class DigitalCredentialTestVerifierActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val requestId = intent.getStringExtra(EXTRA_REQUEST_ID)
        val requestJson = intent.getStringExtra(EXTRA_REQUEST_JSON)
        if (requestId == null || requestJson == null) {
            Log.e("DigitalCredentialE2E", "Verifier Activity was launched without a request handle")
            finish()
            return
        }

        lifecycleScope.launch {
            val result = runCatching {
                CredentialManager.create(this@DigitalCredentialTestVerifierActivity).getCredential(
                    context = this@DigitalCredentialTestVerifierActivity,
                    request = GetCredentialRequest(
                        credentialOptions = listOf(GetDigitalCredentialOption(requestJson)),
                    ),
                )
            }
            result.exceptionOrNull()?.let { Log.e("DigitalCredentialE2E", "Credential Manager request failed", it) }
            DigitalCredentialTestVerifier.complete(requestId, result)
            finish()
        }
    }
}

/** Test-side handoff for [DigitalCredentialTestVerifierActivity]. */
internal class DigitalCredentialRequestHandle internal constructor(
    val id: String,
    private val deferred: CompletableDeferred<Result<GetCredentialResponse>>,
) {
    @Volatile
    private var completedResult: Result<GetCredentialResponse>? = null

    val isComplete: Boolean
        get() = deferred.isCompleted

    internal fun complete(value: Result<GetCredentialResponse>) {
        completedResult = value
        deferred.complete(value)
    }

    internal fun completedResult(): Result<GetCredentialResponse>? = completedResult

    internal fun cancel() {
        deferred.cancel()
    }

    suspend fun await(): Result<GetCredentialResponse> = deferred.await()

    fun abandon() {
        DigitalCredentialTestVerifier.abandon(id)
    }
}

internal object DigitalCredentialTestVerifier {
    private val requests = ConcurrentHashMap<String, DigitalCredentialRequestHandle>()

    fun prepare(): DigitalCredentialRequestHandle {
        val id = UUID.randomUUID().toString()
        val handle = DigitalCredentialRequestHandle(id, CompletableDeferred())
        check(requests.putIfAbsent(id, handle) == null) { "Duplicate Digital Credentials request id $id" }
        return handle
    }

    fun complete(requestId: String, value: Result<GetCredentialResponse>) {
        requests.remove(requestId)?.complete(value)
    }

    fun abandon(requestId: String) {
        requests.remove(requestId)?.cancel()
    }

    fun activeRequestCount(): Int = requests.size
}
