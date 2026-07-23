import java.net.URI

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

val configuredApiBaseUrl = providers.gradleProperty("AVELREN_API_BASE_URL")
    .orElse("https://api.avelren.invalid/")
    .get()
val configuredApiUri: URI = try {
    URI(configuredApiBaseUrl)
} catch (cause: Exception) {
    throw GradleException("AVELREN_API_BASE_URL must be a valid URI", cause)
}

require(configuredApiUri.scheme == "https") {
    "AVELREN_API_BASE_URL must use HTTPS"
}
require(!configuredApiUri.host.isNullOrBlank()) {
    "AVELREN_API_BASE_URL must contain a host"
}
require(
    configuredApiUri.userInfo == null &&
        configuredApiUri.query == null &&
        configuredApiUri.fragment == null,
) {
    "AVELREN_API_BASE_URL must not contain credentials, a query, or a fragment"
}
require(configuredApiUri.path.endsWith("/")) {
    "AVELREN_API_BASE_URL must end with a slash"
}
require('"' !in configuredApiBaseUrl && '\\' !in configuredApiBaseUrl) {
    "AVELREN_API_BASE_URL contains unsupported characters"
}

fun optionalBuildValue(name: String): String =
    providers.gradleProperty(name).orNull.orEmpty().also { value ->
        require('"' !in value && '\\' !in value) { "$name contains unsupported characters" }
    }

android {
    namespace = "ua.ikstv.avelren"
    compileSdk = 37

    defaultConfig {
        applicationId = "ua.ikstv.avelren"
        minSdk = 26
        targetSdk = 37
        versionCode = 1
        versionName = "0.1.0"

        buildConfigField(
            type = "String",
            name = "API_BASE_URL",
            value = "\"$configuredApiBaseUrl\"",
        )
        buildConfigField("String", "FCM_APPLICATION_ID", "\"${optionalBuildValue("AVELREN_FCM_APPLICATION_ID")}\"")
        buildConfigField("String", "FCM_PROJECT_ID", "\"${optionalBuildValue("AVELREN_FCM_PROJECT_ID")}\"")
        buildConfigField("String", "FCM_API_KEY", "\"${optionalBuildValue("AVELREN_FCM_API_KEY")}\"")
        buildConfigField("String", "FCM_SENDER_ID", "\"${optionalBuildValue("AVELREN_FCM_SENDER_ID")}\"")
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        buildConfig = true
        compose = true
    }

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }
}

dependencies {
    implementation(platform(libs.firebase.bom))
    implementation(libs.firebase.messaging)
    implementation(libs.firebase.appcheck.playintegrity)
    implementation(libs.firebase.appcheck.playintegrity)
    implementation(libs.androidx.lifecycle.viewmodel.ktx)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)
    implementation(libs.gson)

    debugImplementation(libs.androidx.compose.ui.tooling)
    debugImplementation(libs.firebase.appcheck.debug)
    debugImplementation(libs.firebase.appcheck.debug)

    testImplementation(libs.kotlinx.coroutines.core)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.junit4)
}
