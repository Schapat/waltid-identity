package id.walt.wallet2.mobile

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Registration and provenance checks for the Google OpenID4VCI issuance matcher.
 *
 * These tests intentionally do not claim to execute the shipped WASM. Credential Manager supplies
 * the matcher host imports on the device; the tests here verify only the bytes we register and the
 * pinned upstream binary metadata. The real matcher behavior requires a physical-device run.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class OpenId4VciIssuanceRegistrationTest {
    private val registry = AndroidDigitalCredentialRegistry(RuntimeEnvironment.getApplication())
    private val assets = RuntimeEnvironment.getApplication().assets

    @Test
    fun shippedWasmContainsTheExpectedCredentialManagerImports() {
        val wasm = assets.open("id/walt/wallet2/mobile/issuance.wasm").use { it.readBytes() }
        val latin1 = wasm.toString(Charsets.ISO_8859_1)

        assertTrue(latin1.contains("AddIssuanceEntry"), "WASM lost the issuance-entry host import")
        assertTrue(latin1.contains("AddStringIdEntry"), "WASM lost the legacy entry host import")
        assertTrue(latin1.contains("SelfDeclarePackageInfo"), "WASM lost the package-info host import")
    }

    @Test
    fun creationOptionsExposeTheAndroidXPackageInfoAndCanonicalProtocolSchema() {
        val creationOptions = registry.encodeOpenId4VciCreationOptions(
            entryId = "openid4vci",
            applicationName = "Demo Wallet",
            subtitle = "Save a credential to this wallet",
            explainer = "Save a credential to this wallet.",
            icon = byteArrayOf(1, 2, 3),
        )
        val registered = creationOptionsJson(creationOptions)

        assertEquals("openid4vci", registered["entry_id"]?.jsonPrimitive?.content)
        assertEquals(
            listOf("openid4vci-v1"),
            registered["preferred_protocols"]!!.jsonArray.map { it.jsonPrimitive.content },
        )
        assertEquals(Json.parseToJsonElement("{\"Pass\":{}}"), registered["filter"])
        assertEquals("Demo Wallet", registered["package_info"]!!.jsonObject["name"]?.jsonPrimitive?.content)
        assertFalse(registered.containsKey("display"))
    }

    @Test
    fun pinnedMatcherRevisionMetadataDocumentsThePackageInfoCompatibilityFix() {
        val notice = assets.open("id/walt/wallet2/mobile/NOTICE-issuance.txt")
            .use { it.readBytes() }
            .decodeToString()

        assertTrue(notice.contains(PINNED_UPSTREAM_COMMIT), "notice lost the pinned matcher revision")
        assertTrue(notice.contains("package_info"), "notice lost the matcher compatibility rationale")
        assertTrue(notice.contains("non-blank entry title"), "notice lost the GMSCore title fallback")
    }

    private fun creationOptionsJson(creationOptions: ByteArray): JsonObject {
        val jsonOffset = ByteBuffer.wrap(creationOptions, 0, 4)
            .order(ByteOrder.LITTLE_ENDIAN)
            .int
        return Json.parseToJsonElement(
            creationOptions.copyOfRange(jsonOffset, creationOptions.size).decodeToString(),
        ).jsonObject
    }

    private companion object {
        const val PINNED_UPSTREAM_COMMIT = "d5a8adc1b84061a4e3a9581cdaf867df89fb1f19"
    }
}
