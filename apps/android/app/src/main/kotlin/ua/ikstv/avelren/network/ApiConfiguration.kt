package ua.ikstv.avelren.network

import ua.ikstv.avelren.BuildConfig

object ApiConfiguration {
    val baseUrl: String
        get() = BuildConfig.API_BASE_URL
}
