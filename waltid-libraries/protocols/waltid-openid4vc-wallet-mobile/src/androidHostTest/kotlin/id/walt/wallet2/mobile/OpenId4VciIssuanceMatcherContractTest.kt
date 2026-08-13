package id.walt.wallet2.mobile

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * Behavioral contract for Google's Rust OpenID4VCI issuance matcher.
 *
 * Credential Manager executes the WASM with host imports that unit tests cannot supply. This suite
 * therefore checks the shipped binary's issuance imports and mirrors the pinned matcher's
 * preferred-protocol decision against the AndroidX-compatible creation-options layout.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class OpenId4VciIssuanceMatcherContractTest {
    private val registry = AndroidDigitalCredentialRegistry(RuntimeEnvironment.getApplication())
    private val assets = RuntimeEnvironment.getApplication().assets

    @Test
    fun shippedWasmIsThePinnedGoogleIssuanceBinary() {
        val wasm = assets.open("id/walt/wallet2/mobile/issuance.wasm").use { it.readBytes() }
        val latin1 = wasm.toString(Charsets.ISO_8859_1)

        assertTrue(latin1.contains("AddIssuanceEntry"), "WASM lost the issuance-entry host import")
        assertTrue(latin1.contains("SelfDeclarePackageInfo"), "WASM lost the package-info host import")
    }

    @Test
    fun googleIssuanceMatcherContractMatchesCanonicalProtocol() {
        val creationOptions = registry.encodeOpenId4VciCreationOptions(
            entryId = "openid4vci",
            applicationName = "Demo Wallet",
            subtitle = "Save a credential to this wallet",
            explainer = "Save a credential to this wallet.",
            icon = byteArrayOf(1, 2, 3),
        )
        val request = buildJsonObject {
            putJsonArray("requests") {
                add(
                    buildJsonObject {
                        put("protocol", "openid4vci-v1")
                        putJsonObject("data") {
                            put("credential_issuer", "https://issuer.example")
                            putJsonArray("credential_configuration_ids") {
                                add(JsonPrimitive("pid"))
                            }
                        }
                    },
                )
            }
        }

        val match = mirrorGoogleIssuanceMatcher(creationOptions, request)
        assertNotNull(match)
        assertEquals("Save a credential to this wallet", match.subtitle)
        assertEquals("Save a credential to this wallet.", match.explainer)
    }

    @Test
    fun preferredProtocolsContainOnlyCanonicalAndRejectAliasesAndUnrelatedProtocols() {
        val creationOptions = registry.encodeOpenId4VciCreationOptions(
            entryId = "openid4vci",
            applicationName = "Demo Wallet",
            subtitle = null,
            explainer = null,
            icon = byteArrayOf(1, 2, 3),
        )
        val registered = creationOptionsJson(creationOptions)
        assertEquals(
            listOf("openid4vci-v1"),
            registered["preferred_protocols"]!!.jsonArray.map { it.jsonPrimitive.content },
        )

        for (protocol in listOf("openid4vci-1.0", "openid4vci1.0", "openid4vp-v1-unsigned")) {
            val request = buildJsonObject {
                putJsonArray("requests") {
                    add(
                        buildJsonObject {
                            put("protocol", protocol)
                            putJsonObject("data") { put("credential_issuer", "https://issuer.example") }
                        },
                    )
                }
            }
            assertEquals(null, mirrorGoogleIssuanceMatcher(creationOptions, request), protocol)
        }
    }

    private fun mirrorGoogleIssuanceMatcher(
        creationOptions: ByteArray,
        dcRequest: JsonObject,
    ): MatchedIssuance? {
        val registered = creationOptionsJson(creationOptions)
        val preferredProtocols = registered["preferred_protocols"]?.jsonArray
            ?.map { it.jsonPrimitive.content }
            .orEmpty()
        if (registered["filter"]?.jsonObject?.containsKey("Pass") != true) return null

        val requests = dcRequest["requests"] as? JsonArray ?: return null
        val matchingRequest = if (preferredProtocols.isNotEmpty()) {
            preferredProtocols.asSequence()
                .flatMap { preferred ->
                    requests.asSequence().filter {
                        it.jsonObject["protocol"]?.jsonPrimitive?.content == preferred
                    }
                }
                .firstOrNull()
        } else {
            requests.firstOrNull { it.jsonObject["protocol"]?.jsonPrimitive?.content == "openid4vci-v1" }
        }
        if (matchingRequest == null) return null

        val entry = registered["entries"]?.jsonArray?.firstOrNull()?.jsonObject ?: return null
        return MatchedIssuance(
            subtitle = entry["subtitle"]?.jsonPrimitive?.content,
            explainer = entry["explainer"]?.jsonObject?.get("default")?.jsonPrimitive?.content,
        )
    }

    private fun creationOptionsJson(creationOptions: ByteArray): JsonObject {
        val jsonOffset = ByteBuffer.wrap(creationOptions, 0, 4)
            .order(ByteOrder.LITTLE_ENDIAN)
            .int
        return Json.parseToJsonElement(
            creationOptions.copyOfRange(jsonOffset, creationOptions.size).decodeToString(),
        ).jsonObject
    }

    private data class MatchedIssuance(
        val subtitle: String?,
        val explainer: String?,
    )
}
