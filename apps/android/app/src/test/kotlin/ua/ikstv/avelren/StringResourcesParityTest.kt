package ua.ikstv.avelren

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.w3c.dom.Document
import org.w3c.dom.Element

class StringResourcesParityTest {

    @Test
    fun `default and uk resources contain same string keys`() {
        val defaultStrings = parseResourceStrings("values/strings.xml")
        val ukStrings = parseResourceStrings("values-uk/strings.xml")

        assertEquals(defaultStrings.keys.sorted(), ukStrings.keys.sorted())
    }

    @Test
    fun `default and uk resources preserve format placeholders`() {
        val defaultStrings = parseResourceStrings("values/strings.xml")
        val ukStrings = parseResourceStrings("values-uk/strings.xml")

        for ((key, defaultValue) in defaultStrings) {
            val ukValue = requireNotNull(ukStrings[key]) { "Missing ukrainian string for key=$key" }
            assertEquals(
                "Placeholder signature mismatch for key=$key",
                placeholderSignatures(defaultValue),
                placeholderSignatures(ukValue),
            )
        }
    }

    @Test
    fun `localized values do not contain combined-language separator`() {
        val defaultStrings = parseResourceStrings("values/strings.xml")
        val ukStrings = parseResourceStrings("values-uk/strings.xml")

        for ((key, value) in defaultStrings) {
            assertFalse("Default string '$key' contains separator", value.contains(" / "))
        }

        for ((key, value) in ukStrings) {
            assertFalse("Ukrainian string '$key' contains separator", value.contains(" / "))
        }
    }

    private fun parseResourceStrings(resourcePath: String): Map<String, String> {
        val file = resolveResourceFile(resourcePath)
        val document: Document = DocumentBuilderFactory.newInstance()
            .newDocumentBuilder()
            .parse(file)
        val nodes = document.documentElement.getElementsByTagName("string")
        val values = mutableMapOf<String, String>()

        for (index in 0 until nodes.length) {
            val node = nodes.item(index)
            if (node is Element) {
                val name = node.getAttribute("name")
                values[name] = node.textContent
            }
        }

        return values
    }

    private fun placeholderSignatures(value: String): List<String> =
        PLACEHOLDER_PATTERN.findAll(value).map { it.value }.toList()

    private fun resolveResourceFile(resourcePath: String): File {
        val candidates = listOf(
            File("src/main/res/$resourcePath"),
            File("apps/android/app/src/main/res/$resourcePath"),
            File("app/src/main/res/$resourcePath"),
            File("../app/src/main/res/$resourcePath"),
            File("../apps/android/app/src/main/res/$resourcePath"),
            File("./$resourcePath"),
        )

        return candidates.firstOrNull { it.exists() }
            ?: throw IllegalArgumentException("Resource file not found: $resourcePath")
    }

    private companion object {
        private val PLACEHOLDER_PATTERN = Regex("%\\d+\\$[sd]")
    }
}
